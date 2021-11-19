#!/usr/bin/env bash
# shellcheck disable=SC2001,SC2068,SC2086,SC2155
# Copyright 2021, NVIDIA Corporation
# SPDX-License-Identifier: MIT

version=("")

err() { echo "ERROR: $*"; print_mismatched; exit 1; }
warn() { warnings+=("$1"); shift; echo "WARN: $*"; }

usage() {
    echo "USAGE: $0 <mirror> [distro] [arch] [version]"
    echo
    echo " PARAMETERS:"
    echo -e "  --mirror=<directory>\t\t input directory"
    echo
    echo " OPTIONAL:"
    echo -e "  --distro=[rhel8,ubuntu2004]\t Linux distro name"
    echo -e "  --arch=[x86_64,ppc64le,sbsa]\t CPU architecture"
    echo -e "  --dryrun\t\t\t skip local files"
    echo -e "  --version=<11.5.0>\t\t filter results by string"
    echo
    err "$*"
}

print_mismatched()
{
    if [[ "${#mismatches[@]}" -gt 0 ]]; then
        echo
        echo "======================"
        for bad in ${mismatches[@]}; do
            echo "$bad" | sed "s|${inputDir}/||"
        done
        echo "Found ${#mismatches[@]} mismatches"
    fi
}

compare_bytes()
{
    bytes=$(du -b "$1" 2>/dev/null | awk '{print $1}')
    if [[ "$bytes" != "$2" ]]; then
        [[ -z $fail ]] && echo && mismatches+=("$1")
        echo " -> size (bytes) mismatch"
        echo "   - Expected: $2"
        echo "   - Computed: $bytes"
        fail=$((fail+1))
    fi
}

compare_sha256()
{
    sha256=$(sha256sum "$1" 2>/dev/null | awk '{print $1}')
    if [[ -z "$2" ]]; then
        [[ -z $fail ]] && echo && mismatches+=("$1")
        echo " -> checksum (SHA256) empty"
        echo "   - Computed:    $sha256"
    elif [[ "$sha256" != "$2" ]]; then
        [[ -z $fail ]] && echo && mismatches+=("$1")
        echo " -> checksum (SHA256) mismatch"
        echo "   - Expected: $2"
        echo "   - Computed: $sha256"
        fail=$((fail+1))
    fi
}

compare_sha1()
{
    sha1=$(sha1sum "$1" 2>/dev/null | awk '{print $1}')
    if [[ -z "$2" ]]; then
        [[ -z $fail ]] && echo && mismatches+=("$1")
        echo " -> checksum (SHA1) empty"
        echo "   - Computed:    $sha1"
    elif [[ "$sha1" != "$2" ]]; then
        [[ -z $fail ]] && echo && mismatches+=("$1")
        echo " -> checksum (SHA1) mismatch"
        echo "   - Expected: $2"
        echo "   - Computed: $sha256"
        fail=$((fail+1))
    fi
}

compare_rpmsign()
{
    rpmsign=$(rpm -qip "$1" 2>&1 | grep "^Signature" | awk -F " : " '{print $NF}' | awk -F ", " '{print $2}')
    if [[ "$rpmsign" != "$2" ]]; then
        [[ -z $fail ]] && echo && mismatches+=("$1")
        echo " -> timestamp (rpmsign) mismatch"
        echo "   - Expected: $2"
        echo "   - Headers:  $rpmsign"
        fail=$((fail+1))
    fi
}

scan_primaries()
{
    manifests=$(find ${repo} -name "*-primary.xml.gz")
    for primaryXML in $manifests; do
        lastUpdate=$(gunzip -c "$primaryXML" | grep "<time" | awk '{print $NF}' | awk -F '"' '{print $2}' | sort -n | head -n 1)
        rpmHistory+=("$lastUpdate:$primaryXML")
    done
    echo "==> Found ${#rpmHistory[@]} repo postings"
}

xml_origin()
{
    local filename=$1

    local filesize=$2
    local sizeA=$(echo "$filesize" | awk -F ":" '{print $1}')
    local sizeB=$(echo "$filesize" | awk -F ":" '{print $2}')

    local checksum=$3
    local hashA=$(echo "$checksum" | awk -F ":" '{print $1}')
    local hashB=$(echo "$checksum" | awk -F ":" '{print $2}')

    echo " -> Deep-scanning for $filename ..."
    local postcount=0

    for posting in $(echo "${rpmHistory[@]}" | sort -k1,1 -t: -n -r); do
        local postmark=$(echo "$posting" | awk -F ":" '{print $1}')
        local postmeta=$(echo "$posting" | awk -F ":" '{print $2}')
        local basemeta=$(basename "$postmeta" 2>/dev/null)
        local timestamp=$(date -d "@${postmark}")

        local oldBlock
        oldBlock=$(gunzip -c "$metadata" | awk '{printf "%s◬",$0} END {print ""}' | sed -e 's|<package |\n<package |g' | grep "$basename" | sed 's|◬|\n|g')
        [[ "$oldBlock" ]] || continue
        postcount=$((postcount+1))

        mBytes=$(echo "$oldBlock" | grep '<size ' | sed 's| |\n|g' | grep "package=" | awk -F "=" '{print $NF}' | sed 's|"||g')
        mSHA256=$(echo "$oldBlock" | grep '<checksum type="sha256"' | sed 's|</checksum>||' | awk -F ">" '{print $NF}')

        if [[ "$mBytes" == "$sizeB" ]]; then
            continue
        elif [[ "$mSHA256" == "$hashB" ]]; then
            continue
        fi


        if [[ "$mSHA256" == "$hashA" ]]; then
            echo "   [ORIGIN] $postmeta ($timestamp)"
            return
        elif [[ "$mBytes" == "$sizeA" ]]; then
            echo "   [BADHASH] $posting ($timestamp)"
        else
            echo "   - $basemeta [$mBytes] [$mSHA256] ($timestamp)"
        fi
    done

    echo "   ::: No correct results found ($postcount)"
}

check_debian()
{
    local metadata="$1"
    local filepath="$2"

    [[ -f "$metadata" ]] || err "Missing metadata file: $metadata"
    [[ -f "$filepath" ]] || err "Missing local package: $filepath"

    basename=$(basename "$filepath" 2>/dev/null)
    shortname=$(echo "$filepath" | sed "s|${repo}/||")

    local pkgBlock
    # Flatten package paragraphs into one-liners (uses special character as delimiter)
    pkgBlock=$(gunzip -c "$metadata" | sed 's|^$|#PACKAGE_BLOCK#|' | awk '{printf "%s◬",$0} END {print ""}' | sed -e 's|◬#PACKAGE_BLOCK#◬|\n|g' | grep "Filename: .*/${basename}" | sed 's|◬|\n|g')
    if [[ -z "$pkgBlock" ]]; then
        warn "$filepath" "no $basename entry in metadata ($metadata)"
        return
    fi

    mBytes=$(echo "$pkgBlock" | grep "^Size:" | awk '{print $NF}' | sort -u)
    mSHA256=$(echo "$pkgBlock" | grep "^SHA256:" | awk '{print $NF}' | sort -u)

    if [[ -n $dryrun ]]; then
        echo -n "$shortname"
        shorthash=$(echo "$mSHA256" | cut -c -10)
        echo " [$mBytes] [$shorthash]"
    else
        unset fail
        echo -n "$shortname"
        compare_bytes "$filepath" "$mBytes"
        compare_sha256 "$filepath" "$mSHA256"
        shorthash=$(echo "$sha256" | cut -c -10)

        if [[ -z $fail ]]; then
            echo " [$bytes] [$shorthash]"
        fi
    fi
}

check_rpm()
{
    local metadata="$1"
    local filepath="$2"

    [[ -f "$metadata" ]] || err "Missing metadata file: $metadata"
    [[ -f "$filepath" ]] || err "Missing local package: $filepath"

    basename=$(basename "$filepath" 2>/dev/null)
    shortname=$(echo "$filepath" | sed "s|${repo}/||")

    local pkgBlock
    # Flatten package XML tags into one-liners (uses special character as delimiter)
    pkgBlock=$(gunzip -c "$metadata" | awk '{printf "%s◬",$0} END {print ""}' | sed -e 's|<package |\n<package |g' | grep "href=""\"${basename}""\"/>" | sed 's|◬|\n|g')
    if [[ -z "$pkgBlock" ]]; then
        warn "no $basename entry in metadata ($metadata)"
        return
    fi

    mBytes=$(echo "$pkgBlock" | grep '<size ' | sed 's| |\n|g' | grep "package=" | awk -F "=" '{print $NF}' | sed 's|"||g' | sort -u)
    mSHA256=$(echo "$pkgBlock" | grep '<checksum type="sha256"' | sed 's|</checksum>||' | awk -F ">" '{print $NF}' | sort -u)
    mSHA1=$(echo "$pkgBlock" | grep '<checksum type="sha"' | sed 's|</checksum>||' | awk -F ">" '{print $NF}' | sort -u)
    mTimestamp=$(echo "$pkgBlock" | grep '<time ' | sed 's| |\n|g' | grep "file=" | awk -F "=" '{print $NF}' | sed 's|"||g' | sort -u)
    mHumanTime=$(date -d "@${mTimestamp}")

    if [[ -n $dryrun ]]; then
        echo -n "$shortname"
        shorthash=$(echo "$mSHA256" | cut -c -10)
        echo " [$mBytes] [$shorthash]"
    else
        unset fail
        echo -n "$shortname"
        compare_bytes "$filepath" "$mBytes"

        if [[ -z "$mSHA256" ]] && [[ -n "$mSHA1" ]]; then
            compare_sha1 "$filepath" "$mSHA1"
        else
            compare_sha256 "$filepath" "$mSHA256"
        fi

        if [[ -z $fail ]]; then
            shorthash=$(echo "$sha256" "$sha1" | cut -c -10)
            echo " [$bytes] [$shorthash]"
        else
            compare_rpmsign "$filepath" "$mHumanTime"
            xml_origin "$basename" "$bytes:$mBytes" "$sha256:$mSHA256"
        fi
    fi
}

file_parse()
{
    local repotype="$1"
    local metadata="$2"
    local filename="$3"

    if [[ "$repotype" == "rpm" ]]; then
        check_rpm "$metadata" "$filename"
    elif [[ "$repotype" == "debian" ]]; then
        check_debian "$metadata" "$filename"
    else
        err "Unknown repository type: $repotype"
    fi
}

precheck_files()
{
    stored=0
    queued=0
    unset downloads

    # Pre-check packages
    for file in $@; do
        if [[ -f ${repo}/${file} ]]; then
            downloads+=("${repo}/${file}")
            stored=$((stored + 1))
        else
            queued=$((queued + 1))
        fi
    done

    if [[ $stored -gt 0 ]]; then
        echo ":: Found $stored local files"
    fi
}

validate_files()
{
    local repotype="$1"
    local metafile="$2"
    shift; shift
    precheck_files $@

    if [[ $queued -gt 0 ]]; then
        echo "[WARNING] :: Missing $queued repo files"
        echo
    else
        echo ":: Up-to-date"
    fi

    # Validate packages
    for file in ${downloads[@]}; do
        if [[ -f $file ]]; then
            file_parse "$repotype" "$metafile" "$file"
        elif [[ -n $dryrun ]]; then
            echo "[SKIP] $file"
        else
            err "[NOT FOUND] $file"
        fi
    done
}

parse_debian_repo()
{
    local relPath
    if [[ -n "$metaDir" ]]; then
        relPath="$metaDir/${distro}/${arch}"
    else
        relPath="$repo"
    fi

    repoDEB=("Release" "Release.gpg" "Packages" "Packages.gz")
    metaFiles=$(echo ${repoDEB[@]} | sed 's| |\n|g')
    gzipPath=$(echo "$metaFiles" | grep "\.gz")

    echo "==> Parsing $gzipPath"
    textBlocks=$(gunzip -c "${relPath}/${gzipPath}" 2>/dev/null)
    packageFiles=$(echo "$textBlocks" | grep -E "$matching" | grep "^Filename: " | awk -F './' '{print $2}')

    if [[ -z "$packageFiles" ]]; then
        echo "ERROR: Unable to locate packages in repository for ${distro}/${arch}"
        return
    fi

    validate_files debian "${relPath}/${gzipPath}" "$packageFiles"
}

parse_rpm_repo()
{
    local relPath
    if [[ -n "$metaDir" ]]; then
        relPath="$metaDir/${distro}/${arch}"
    else
        relPath="$repo"
    fi

    repoMD="${relPath}/repodata/repomd.xml"
    metaFiles=$(grep "href=" "$repoMD" 2>/dev/null | awk -F '"' '{print $2}')
    gzipPath=$(echo "$metaFiles" | grep primary\.xml)

    echo "==> Parsing $gzipPath"
    primaryXML=$(gunzip -c "${relPath}/${gzipPath}" 2>/dev/null)
    packageFiles=$(echo "$primaryXML" | grep -E "$matching" | grep "<location" | awk -F '"' '{print $2}')

    if [[ -z "$packageFiles" ]]; then
        echo "ERROR: Unable to locate packages in repository for ${distro}/${arch}"
        return
    fi

    validate_files rpm "${relPath}/${gzipPath}" "$packageFiles"
}


# Options
while [[ $1 =~ ^-- ]]; do
    # Do not download files
    if [[ $1 =~ "dryrun" ]] || [[ $1 =~ "dry-run" ]]; then
        dryrun=1
    # Specify Linux distro
    elif [[ $1 =~ "distro=" ]]; then
        distro=$(echo "$1" | awk -F "=" '{print $2}')
    elif [[ $1 =~ ^--distro$ ]]; then
        shift; distro="$1"
    # Specify architecture
    elif [[ $1 =~ "arch=" ]]; then
        arch=$(echo "$1" | awk -F "=" '{print $2}')
    elif [[ $1 =~ ^--arch$ ]]; then
        shift; arch="$1"
    # Package directory
    elif [[ $1 =~ "mirror=" ]]; then
        mirrorDir=$(echo "$1" | awk -F "=" '{print $2}')
        directory=$(readlink -m "$mirrorDir")
    elif [[ $1 =~ ^--mirror$ ]]; then
        shift; directory=$(readlink -m "$1")
    # Metadata
    elif [[ $1 =~ "metadata=" ]]; then
        metaDir=$(echo "$1" | awk -F "=" '{print $2}')
    elif [[ $1 =~ ^--metadata$ ]]; then
        shift; metaDir="$1"
    # Version array
    elif [[ $1 =~ "version=" ]]; then
        version+=("$(echo $1 | awk -F '=' '{print $2}')")
    elif [[ $1 =~ ^--version$ ]]; then
        shift; version+=("$1")
    fi
    shift
done


# Flatten version array
matching=$(echo "${version[@]}" | sed -e 's|^ ||' -e 's| $||' -e 's/ /|/g')

# Overrides
if [[ -n "$directory" ]]; then
    inputDir="$directory"
fi

[[ -n $inputDir ]]   || usage "Must specify --mirror directory"

# Scan multiple repos
for repo in $(find "$inputDir" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | grep -e "$arch" | grep -e "$distro"); do
    dirname=$(dirname "$repo" 2>/dev/null)
    parentDir=$(basename "$dirname" 2>/dev/null)
    rpmDistro=$(echo "$parentDir" | grep -o -e "fedora" -e "rhel" -e "sles" -e "suse")
    debDistro=$(echo "$parentDir" | grep -o -e "debian" -e "ubuntu")

    if [[ -n "$rpmDistro" ]]; then
        echo "===== $repo (RPM) ====="
        scan_primaries
        parse_rpm_repo
    elif [[ -n "$debDistro" ]]; then
        echo "===== $repo (DEB) ====="
        parse_debian_repo
    else
        echo "ERROR: Unsupported distro: $repo"
        continue
    fi
    echo
done

print_mismatched

### END ###
