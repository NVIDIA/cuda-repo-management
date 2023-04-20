#!/usr/bin/env bash
# shellcheck disable=SC2068,SC2164,SC2086,SC2155,SC2207
# Copyright 2021, NVIDIA Corporation
# SPDX-License-Identifier: MIT

publicKey="3bf863cc" # set this to shortname for GPG keypair


err() { echo "ERROR: $*"; exit 1; }

usage() {
    echo "USAGE: $0 <input> <mirror> <repo> [workdir] [gpgkey]"
    echo
    echo " PARAMETERS:"
    echo -e "  --input=<directory>\t overlay with changes"
    echo -e "  --mirror=<directory>\t source of truth"
    echo -e "  --repo=<subdirectory>\t \$distro/\$arch to traverse"
    echo
    echo " OPTIONAL:"
    echo -e "  --nocache\t\t rebuild metadata"
    echo -e "  --gpgkey=<name>\t shortname for GPG signing keypair"
    echo -e "  --workdir=<directory>\t scratch area for temp files"
    echo
    [[ -n $1 ]] && err "$*"
    [[ -z $1 ]] && exit 0
}

compare_file() {
    local file1=$(md5sum "$mirror/$2/$3" | awk '{print $1}')
    local file2=$(md5sum "$1/$2/$3" | awk '{print $1}')
    echo " -> [file1] $mirror/$2/$3: $file1"
    echo " -> [file2] $1/$2/$3: $file2"
    if [[ "$file1" == "$file2" ]]; then
        echo ":: files are identical"
        return 0
    else
        echo ":: files are different"
        return 1
    fi
}

get_checksum() {
    local dir="$1"
    md5sum "$dir"/* | sed 's|\/| |g' | awk '{print $1,$NF}' | sort -k2
}

deb_md5sum() {
    local parent="$1"
    local subpath="$2"

    debs=$(find "$parent/$subpath" -mindepth 1 -maxdepth 1 -type f \( -not -name "*.deb" \) 2>/dev/null | sort)
    if [[ -n "$debs" ]]; then
        echo "==> $parent/$subpath"
        md5sum $debs | sed 's|\/| |g' | awk '{print $1,$NF}' | sort -k2
    fi
}

compare_debian_md5sum() {
    [[ -d "$1" ]] || err "USAGE: compare_debian_md5sum() <dir1> [dir2] [subpath]"
    [[ -d "$2" ]] || err "USAGE: compare_debian_md5sum() [dir1] <dir2> [subpath]"
    [[ -n "$3" ]] || err "USAGE: compare_debian_md5sum() [dir1] [dir2] <subpath>"

    file1=$(deb_md5sum "$1" "$3")
    file2=$(deb_md5sum "$2" "$3")

    echo "$file1"
    echo "---"
    echo "$file2"
    echo "---------"

    two_way=$(comm -1 -3 <(echo "$file1" | sort) <(echo "$file2" | sort) | grep -v "^==>" | sort -k2)
    echo "$two_way"

    for line in $(echo "$two_way" | awk '{print $2}'); do
        echo "${subpath}/${line}" >> "$fileManifest"
    done

    diff_count=$(echo "$two_way" | wc -l)
    [[ $diff_count -gt 1 ]] || err "metadata unchanged"
    echo ":: $diff_count metadata file(s) added or modified"
}

deb_pkg_stale() {
    local donor_file=$(echo "$1" | sed -e 's|$|\.stale|' -e 's|\.old||')
    local stale_count=$(echo "$old_packages" | wc -l)
    [[ $stale_count -gt 0 ]] || return
    echo ">>> deb_pkg_stale($stale_count)"
    [[ -f "$1" ]] &&
    rsync -a "$1" "$donor_file"

    for pkg in $old_packages; do
        context=$(grep -nE -e "^$" -e "^Filename:" "$donor_file" 2>/dev/null | grep -C1 -E "Filename:( |.*/)${pkg}$")
        length=$(wc -l "$donor_file" 2>/dev/null | awk '{print $1}')
        block_new=$(echo "$context" | grep ":$" | sed 's|:||' | head -n1)
        block_end=$(echo "$context" | grep ":$" | sed 's|:||' | tail -n1)
        head -n "$block_new" "$donor_file" > "${donor_file}.head"
        tail -n $((length-block_end)) "$donor_file" > "${donor_file}.tail"
        cat "${donor_file}.head" "${donor_file}.tail" > "${donor_file}"
        echo ":: removed $pkg"
        rm -f "${donor_file}.head" "${donor_file}.tail"
    done
    echo
}

find_tag() {
    local index=0
    for key in ${pkg_tags[@]}; do
        if [[ "$key" == "null" ]]; then
            pkg_tags[$index]="null"
        elif [[ "$key" == "$1" ]] || [[ -z "$1" ]]; then
            value=$(dpkg-deb --field "$filename" "$key")
            echo "$key: $value"
            pkg_tags[$index]="null"
        fi
        index=$((index+1))
    done
}

deb_pkg_info() {
    #
    # Function replaces tools like apt-ftparchive and dpkg-scanpackages
    #

    [[ -f "$1" ]] || err "deb_pkg_info() file $1 not found"

    # Calculate some values
    pkg_size=$(du -L -b "$1" 2>/dev/null | awk '{print $1}')
    pkg_md5=$(md5sum "$1" 2>/dev/null | awk '{print $1}')
    pkg_sha1=$(sha1sum "$1" 2>/dev/null | awk '{print $1}')
    pkg_sha256=$(sha256sum "$1" 2>/dev/null | awk '{print $1}')
    pkg_sha512=$(sha512sum "$1" 2>/dev/null | awk '{print $1}')

    # Order matters
    filename="$1"
    pkg_tags=($(dpkg --info "$filename" | sed 's/^ //' | grep -E "^[A-Za-z-]+:" | awk -F ":" '{print $1}'))
    find_tag "Package"
    find_tag "Version"
    find_tag "Architecture"
    find_tag "Multi-Arch"
    find_tag "Priority"
    find_tag "Section"
    find_tag "Source"
    find_tag "Origin"
    find_tag "Maintainer"
    find_tag "Original-Maintainer"
    find_tag "Bugs"
    find_tag "Installed-Size"
    find_tag "Provides"
    find_tag "Depends"
    find_tag "Recommends"
    find_tag "Suggests"
    find_tag "Conflicts"
    find_tag "Breaks"
    find_tag "Replaces"

    # Append calculated values
    echo "Filename: ./$1"
    echo "Size: $pkg_size"
    echo "MD5sum: $pkg_md5"
    echo "SHA1: $pkg_sha1"
    echo "SHA256: $pkg_sha256"
    echo "SHA512: $pkg_sha512"

    # Append package description
    find_tag "Homepage"
    find_tag "Description"

    # Anything leftover
    find_tag
}

deb_metadata() {
    local donor="$1"
    local parent="$2"
    local subpath="$3"
    local oldPWD="$PWD"

    if [[ -d "${donor}/${subpath}" ]] && [[ -z "$nocache" ]]; then
        echo ":: Get bytes from donor Packages.gz"
        # Get bytes from donor Packages.gz
        cd "${donor}/${subpath}" || err "unable to cd to $donor / $subpath"
        donorManifest=$(gunzip -c Packages.gz 2>/dev/null)
        bytes1=$(echo "$donorManifest" | grep -e "^Filename:" -e "^Size:" | awk '{print $NF}')
        bytes1=$(echo "$bytes1" | sed 's|\.\/| |' | paste -d " " - - | awk '{print $2, $1}' | column -t | sort)

        cd "${parent}/${subpath}" || err "unable to cd to $parent / $subpath"
        echo -n "..."

        # Calculate bytes from local DEB packages
        bytes2=$(du -L -b -- *.deb | column -t | sort)
        echo -n "..."

        # Skip unmodified packages
        byte_compare=$(comm -1 -3 <(echo "$bytes1" | sort) <(echo "$bytes2"))
        deb_packages=$(echo "$byte_compare" | awk '{print $NF}' | sort)

        # Track modified packages
        stale_crumbs=$(comm -2 -3 <(echo "$bytes1" | sort) <(echo "$bytes2"))
        old_packages=$(echo "$stale_crumbs" | awk '{print $NF}' | sort)
        echo "..."
    else
        echo ":: From scratch"
        cd "${parent}/${subpath}" || err "unable to cd to $parent / $subpath"
        deb_packages=$(find . -maxdepth 1 -name "*.deb" -exec stat -c "%y %n" {} + 2>/dev/null | awk '{print $1,$NF}' | sort | awk '{print $NF}' | sed 's|\.\/| |')
    fi


    pkg_count=$(echo "$deb_packages" | grep -v ^$ | wc -l)
    [[ $pkg_count -gt 0 ]] || echo "WARNING: no new packages - intentionally empty?"
    echo ">>> deb_pkg_info($pkg_count)"
    cd "${inputDir}/${subpath}" || err "unable to cd to $inputDir / $subpath"

    #
    # Manually process new or modified Debian packages
    #
    PackagesNew="Packages.new"
    rm -f "$PackagesNew"
    touch "$PackagesNew"
    for pkg in $deb_packages; do
        deb_pkg_info "$pkg" >> "$PackagesNew"
        echo >> "$PackagesNew"
        echo "$pkg"
        echo ${subpath}/${pkg} >> "$fileManifest"
    done
    echo

    # Append and rename
    PackagesOld="Packages.old"
    PackagesFix="Packages.stale"
    if [[ -n "$donorManifest" ]]; then
        echo "$donorManifest" > "$PackagesOld"
        echo >> "$PackagesOld"

        deb_pkg_stale "$PackagesOld"
        [[ -f "$PackagesFix" ]] && PackagesOld="$PackagesFix"

        echo "[Merge] :: cat $PackagesOld $PackagesNew > Packages"
        cat "$PackagesOld" "$PackagesNew" > Packages
    else
        echo "[New] :: mv -v $PackagesNew Packages"
        mv -v "$PackagesNew" Packages
    fi

    [[ -f "Packages" ]] || err "Packages file not found"

    # Compress manifest
    gzip -c -9 -f Packages > Packages.gz
    echo ":: Packages.gz"
    [[ -f "Packages.gz" ]] || err "Packages.gz file not found"

    # Calculate hashes
    txt_bytes=$(wc --bytes Packages | awk '{print $1}')
    txt_md5=$(md5sum Packages | awk '{print $1}')
    txt_sha1=$(sha1sum Packages | awk '{print $1}')
    txt_sha256=$(sha256sum Packages | awk '{print $1}')

    gz_bytes=$(wc --bytes Packages.gz | awk '{print $1}')
    gz_md5=$(md5sum Packages.gz | awk '{print $1}')
    gz_sha1=$(sha1sum Packages.gz | awk '{print $1}')
    gz_sha256=$(sha256sum Packages.gz | awk '{print $1}')

    # Build checksum file
    Release="Release.new"
    pkg_arch=$(basename "$subpath")
    pkg_date=$(date -R -u)
    {
      echo "Origin: NVIDIA"
      echo "Label: NVIDIA CUDA"
      echo "Architecture: ${pkg_arch}"
      echo "Date: ${pkg_date}"
      echo "MD5Sum:"
      printf " %s %48d %s\n" $txt_md5 $txt_bytes Packages
      printf " %s %48d %s\n" $gz_md5 $gz_bytes Packages.gz
      echo "SHA1:"
      printf " %s %40d %s\n" $txt_sha1 $txt_bytes Packages
      printf " %s %40d %s\n" $gz_sha1 $gz_bytes Packages.gz
      echo "SHA256:"
      printf " %s %16d %s\n" $txt_sha256 $txt_bytes Packages
      printf " %s %16d %s\n" $gz_sha256 $gz_bytes Packages.gz

      # FIXME prevent hash mismatch error
      echo "Acquire-By-Hash: no"
    } > "$Release"

    # Rename
    mv -v "$Release" Release
    [[ -f "Release" ]] || err "Release file not found"
    echo ":: Release"
    cat Release
    echo

    echo "==> Sanity check for Release"
    if [[ -f "$mirror/$subpath/Release" ]]; then
        compare_file "$parent" "$subpath" "Release" && err "expected new metadata"
    else
        echo " :: Old repo not found"
    fi
    echo

    # Sign checksum file with key
    if [[ $gpgkeyName == "UNSIGNED" ]]; then
        echo "==> Skipping signing (use external signing server)"
    else
        echo ">>> gpg -u ${gpgkeyName} --yes --armor --detach-sign --personal-digest-preferences SHA512 --output Release.gpg Release"
        gpg -u ${gpgkeyName} --yes --armor --detach-sign --personal-digest-preferences SHA512 --output Release.gpg Release || err "gpg failed to detach signature"
        [[ -f "Release.gpg" ]] || err "Release.gpg file not found"
        echo ":: Release.gpg"
        gpg -u ${gpgkeyName} --yes --clearsign --personal-digest-preferences SHA256 --output InRelease Release || err "InRelease failed"
        [[ -f "InRelease" ]] || err "InRelease file not found"
        echo ":: InRelease"
    fi

    cd "$oldPWD" >/dev/null
    echo

    if [[ -z "$nocache" ]]; then
        compare_debian_md5sum "$mirror" "$inputDir" "$subpath"
        echo
    fi
}


# Options
while [[ $1 =~ ^-- ]]; do
    # Full rebuild of metadata
    if [[ $1 =~ ^--nocache$ ]] || [[ $1 =~ ^--no-cache$ ]]; then
        nocache=1
    # Repository relative path
    elif [[ $1 =~ "repo=" ]]; then
        subpath=$(echo "$1" | awk -F "=" '{print $2}')
    elif [[ $1 =~ ^--repo$ ]]; then
        shift; subpath="$1"
    # Repository architecture
    elif [[ $1 =~ "arch=" ]]; then
        arch=$(echo "$1" | awk -F "=" '{print $2}')
    elif [[ $1 =~ ^--arch$ ]]; then
        shift; arch="$1"
    # Repository distro name
    elif [[ $1 =~ "distro=" ]]; then
        distro=$(echo "$1" | awk -F "=" '{print $2}')
    elif [[ $1 =~ ^--distro$ ]]; then
        shift; distro="$1"
    # Scratch directory
    elif [[ $1 =~ "workdir=" ]]; then
        workDir=$(echo "$1" | awk -F "=" '{print $2}')
    elif [[ $1 =~ ^--workdir$ ]]; then
        shift; workDir="$1"
    # Source of truth
    elif [[ $1 =~ "mirror=" ]]; then
        mirror=$(echo "$1" | awk -F "=" '{print $2}')
    elif [[ $1 =~ ^--mirror$ ]]; then
        shift; mirror="$1"
    # Release candidate
    elif [[ $1 =~ "input=" ]]; then
        inputDir=$(echo "$1" | awk -F "=" '{print $2}')
    elif [[ $1 =~ ^--input$ ]]; then
        shift; inputDir="$1"
    # Signing key name
    elif [[ $1 =~ "gpg=" ]] || [[ $1 =~ "gpgkey=" ]]; then
        gpgkeyName=$(echo "$1" | awk -F "=" '{print $2}')
    elif [[ $1 =~ ^--gpg$ ]] || [[ $1 =~ ^--gpgkey$ ]]; then
        shift; gpgkeyName="$1"
    elif [[ $1 =~ ^--help$ ]]; then
        usage
    fi
    shift
done


[[ -d "$inputDir" ]] || usage "Must specify --input directory (read-write)"
[[ ! -d "$mirror" ]] && [[ -z $nocache ]] && usage "Must specify --mirror directory (read-only)"
[[ -d "$mirror" ]] && [[ -z "$subpath" ]] && usage "Must specify --repo relative subdirectory (\$distro/\$arch)"

# Set default signing key
[[ -n "$gpgkeyName" ]] || gpgkeyName="$publicKey"

# Temp files
[[ -n "$workDir" ]] || workDir=$(mktemp -d)
[[ -d "$workDir" ]] || mkdir -p "$workDir"
fileManifest="${workDir}/manifest.list"

# Update Debian metadata
deb_metadata "$mirror" "$inputDir" "$subpath"

### END ###
