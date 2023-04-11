#!/usr/bin/env bash
# shellcheck disable=SC2002,SC2164,SC2012,SC2086,SC2155
# Copyright 2021, NVIDIA Corporation
# SPDX-License-Identifier: MIT

publicKey="D42D0685" # set this to shortname for GPG keypair
moduleName="nvidia-driver"

current=$(readlink -e "$(dirname ${BASH_SOURCE[0]})")
parent=$(dirname "$current")
genmodulesLOCAL="${current}/genmodules.py"
genmodulesPARENT="${parent}/genmodules.py"
genmodulesPATH=$(type -p genmodules.py)


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
    err "$*"
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

rpm_md5sum() {
    local parent="$1"
    local subpath="$2"

    rpms=$(find "$parent/$subpath" -mindepth 1 -maxdepth 1 -type d -name "repodata" 2>/dev/null | sort)
    for rpm_repo in $rpms; do
        echo "==> $rpm_repo"
        get_checksum "$rpm_repo"
    done
}

compare_rpm_md5sum() {
    [[ -d "$1" ]] || err "USAGE: compare_rpm_md5sum() <dir1> [dir2] [subpath]"
    [[ -d "$2" ]] || err "USAGE: compare_rpm_md5sum() [dir1] <dir2> [subpath]"
    [[ -n "$3" ]] || err "USAGE: compare_rpm_md5sum() [dir1] [dir2] <subpath>"

    file1=$(rpm_md5sum "$1" "$3")
    file2=$(rpm_md5sum "$2" "$3")

    echo "$file1"
    echo "---"
    echo "$file2"
    echo "---------"

    two_way=$(comm -1 -3 <(echo "$file1" | sort) <(echo "$file2" | sort) | grep -v "^==>" | sort -k2)
    echo "$two_way"

    for line in $(echo "$two_way" | awk '{print $2}'); do
        echo "${subpath}/repodata/${line}" >> "$fileManifest"
    done

    diff_count=$(echo "$two_way" | wc -l)
    [[ $diff_count -gt 1 ]] || err "metadata unchanged"
    echo ":: $diff_count metadata file(s) added or modified"
}

check_modular() {
    local distnum=$(echo "$distro" | tr -dc '0-9\n')

    if [[ "$distro" =~ "rhel" ]] && [[ "$distnum" -ge 8 ]]; then
        echo "Detected RHEL >= 8, turning on modularity"
        modular=1
    elif [[ "$distro" =~ "fedora" ]] && [[ "$distnum" -ge 28 ]]; then
        echo "Detected Fedora >= 28, turning on modularity"
        modular=1
    elif [[ "$distro" =~ "kylin" ]]; then
        echo "Detected Kylin, turning on modularity"
        modular=1
    else
        echo "Non modularity distro detected ($distro : $distnum), keeping modularity off"
        return 0
    fi

    if [[ -f "$genmodulesLOCAL" ]]; then
        genmodules="$genmodulesLOCAL"
    elif [[ -f "$genmodulesPARENT" ]]; then
        genmodules="$genmodulesPARENT"
    elif [[ -n "$genmodulesPATH" ]]; then
        genmodules="$genmodulesPATH"
    elif [[ -z "$remoteModules" ]] && [[ -z "$localModules" ]]; then
        echo
        echo ":: Skipping modularity, no $moduleName packages found"
        echo
    elif [[ -n "$moduleName" ]]; then
        echo
        echo ">>> [$moduleName] modularity"
        echo "NOTICE: fetch genmodules.py script from https://github.com/NVIDIA/yum-packaging-precompiled-kmod"
        err "unable to locate 'genmodules.py' in $current or \$PATH"
    fi
}

rpm_modularity() {
    local rpmdir="$1"

    if [[ $modular -ne 1 ]]; then
        return
    fi

    echo "Running modularity with (remoteModules = $remoteModules) (localModules = $localModules)"
    # Driver streams expect driver packages present
    if [[ -n "$remoteModules" ]] || [[ -n "$localModules" ]]; then
        echo "%%%%%%%%%%%%%%%%%%"
        echo "%%% Modularity %%%"
        echo "%%%%%%%%%%%%%%%%%%"

        echo ">>> python3 $genmodules $rpmdir $rpmdir/modules.yaml"
        python3 $genmodules "$rpmdir" ${rpmdir}/modules.yaml || err "./genmodules.py $rpmdir $rpmdir/modules.yaml"
        [[ -f "${rpmdir}/modules.yaml" ]] || err "modules.yaml not found at $rpmdir"
        echo

        echo ">>> modifyrepo_c modules.yaml $rpmdir/repodata"
        modifyrepo_c ${rpmdir}/modules.yaml $rpmdir/repodata || err "modifyrepo_c ${rpmdir}/modules.yaml ${rpmdir}/repodata"
        echo
    else
        echo "Skipping modularity as there's no local/remote modules"
    fi
}

rpm_metadata() {
    local donor="$1"
    local parent="$2"
    local subpath="$3"
    repomd="repodata/repomd.xml"
    oldPWD="$PWD"

    cd "$parent"/"$subpath" || err "unable to cd to $parent / $subpath"

    #FIXME WAR for overlayFS invalid cross-device link
    if [[ -n "$DEVMODE" ]]; then
        echo "[FIXME] remove old repo metadata files"
    else
        [[ -d repodata ]] &&
        mkdir old &&
        mv repodata old
    fi

    #
    # Process new or modified RPM packages
    #
    if [[ -z "$nocache" ]]; then
        repoArgs="--update --update-md-path $PWD/old"
    #
    # Process all RPM packages
    #
    else
        unset repoArgs
    fi

    echo ">>> createrepo_c -v --database $repoArgs $PWD"
    createrepo_c -v --database $repoArgs "$PWD" 2>&1 | tee "$logFile"
    [[ ${PIPESTATUS[0]} -eq 0 ]] || err "createrepo_c failed"
    echo

    pkg_cache=$(cat "$logFile" 2>/dev/null | grep "CACHE HIT" | awk '{print $NF}')
    pkg_modify=$(cat "$logFile" 2>/dev/null | grep "metadata are obsolete" | awk '{print $2}')
    pkg_list=$(find "$PWD" -maxdepth 1 -type f -name "*.rpm" 2>/dev/null | awk -F '/' '{print $NF}')
    pkg_diff=$(comm -1 -3 <(echo "$pkg_cache" | sort) <(echo "$pkg_list" | sort))
    for pkg in $(echo -e "${pkg_diff}\n${pkg_modify}" | sort -u); do
        echo ":: ${subpath}/${pkg}"
        echo "${subpath}/${pkg}" >> "$fileManifest"
    done
    echo

    # Modularity
    if [[ -n "$modular" ]]; then
        rpm_modularity "$PWD"
    fi

    echo "==> Sanity check for repomd.xml"
    if [[ -n "$mirror" ]] && [[ -f $mirror/$subpath/$repomd ]]; then
        compare_file "$parent" "$subpath" "$repomd" && err "expected new metadata"
    else
        echo " :: Old repo not found"
    fi
    echo

    # Sign checksum file with key
    if [[ $gpgkeyName == "UNSIGNED" ]]; then
        echo "==> Skipping signing (use external signing server)"
    else
        echo ">>> gpg --batch --yes -a -u ${gpgkeyName} --detach-sign --personal-digest-preferences SHA512 $repomd"
        gpg --batch --yes -a -u ${gpgkeyName} --detach-sign --personal-digest-preferences SHA512 "$repomd" || err "repomd.xml.asc failed"
        echo ">>> gpg --batch --yes -a --export ${gpgkeyName} > ${repomd}.key"
        gpg --batch --yes -a --export ${gpgkeyName} > ${repomd}.key || err "repomd.xml.key failed"
        echo
    fi

    # Preserve old repodata
    if [[ -d "old/repodata" ]]; then
        mv -v repodata/* old/repodata/
        rmdir repodata
        mv old/repodata repodata
        rmdir old
    fi

    rmdir old 2>/dev/null
    cd "$oldPWD" >/dev/null
    echo

    if [[ -d "$donor" ]] && [[ -z $nocache ]]; then
        compare_rpm_md5sum "$donor" "$inputDir" "$subpath"
    fi
    echo
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
    fi
    shift
done


[[ -d "$inputDir" ]] || usage "Must specify --input directory (read-write)"

# Allow --repo parameter to be optional
if [[ -z "$subpath" ]]; then
    nestPath=$(basename "$inputDir" 2>/dev/null)
    inputDir=$(dirname "$inputDir" 2>/dev/null)
    basePath=$(basename "$inputDir" 2>/dev/null)
    inputDir=$(dirname "$inputDir" 2>/dev/null)
    subpath="${basePath}/${nestPath}"
fi

# Set default signing key
[[ -n "$gpgkeyName" ]] || gpgkeyName="$publicKey"

# Temp files
[[ -n "$workDir" ]] || workDir=$(mktemp -d)
[[ -d "$workDir" ]] || mkdir -p "$workDir"
fileManifest="${workDir}/manifest.list"
logFile="${workDir}/createrepo.log"
rm -f -- "$logFile"

# Detect modularity
localModules=$(ls ${inputDir}/${subpath}/${moduleName}* 2>/dev/null | awk NR==1)
remoteModules=$(ls ${mirror}/${subpath}/${moduleName}* 2>/dev/null | awk NR==1)
check_modular

# Update RPM metadata
rpm_metadata "$mirror" "$inputDir" "$subpath"

### END ###
