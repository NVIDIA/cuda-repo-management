#!/usr/bin/env bash
# shellcheck disable=SC2001,SC2012,SC2048,SC2068,SC2076,SC2086,SC2128,SC2155,SC2199
# Copyright 2021, NVIDIA Corporation
# SPDX-License-Identifier: MIT

current=$(readlink -e "$(dirname ${BASH_SOURCE[0]})")
debianMetadata="${current}/repo-debian.sh"
rpmMetadata="${current}/repo-rpm.sh"

outputDir="$PWD/new"
tempDir="$PWD"
imgSize="2048" # 2 GiB
optimize=1     # try to reduce image size

uidmapping="squash_to_uid=$(id -u),squash_to_gid=$(id -g)"
FUSEOPTS+="$uidmapping"

clean_up() {
    cd /
    [[ -d "$mountDir" ]] && [[ -n "$rootless" ]] && fusermount -u "$mountDir"
    [[ -d "$mountDir" ]] && [[ -z "$rootless" ]] && sudo umount "$mountDir"
    [[ -d "$mountDir" ]] && rmdir "$mountDir"
    [[ -d "$mountDir" ]] && [[ -z "$rootless" ]] && sudo umount -l "$mountDir"
    [[ -d "$scratch"  ]] && [[ -z "$rootless" ]] && sudo umount "$scratch"
    [[ -f "$onetimeFS" ]] && rm "$onetimeFS"
    [[ -d "$mountDir" ]] && rmdir "$mountDir"
    [[ -d "$scratch"  ]] && rm -rf "$scratch"
    [[ -d "$tempDir/tmp" ]] && rmdir "$tempDir/tmp"
}

trap ctrl_c INT
ctrl_c() {
    echo "==> Mischief managed"
    clean_up
    exit 1
}

err() {
    echo "ERROR: $*"
    clean_up
    exit 1
}

usage() {
    echo "USAGE: $0 [options] <mirror> <dir> { [dir] ... }"
    echo
    echo " PARAMETERS:"
    echo -e "  --mirror=<directory>\t source of truth public snapshot\t\t $mirror"
    echo -e "  <dir>\t\t\t one or more input directories to overlay\t $ARGS"
    echo
    echo " OPTIONS:"
    echo -e "  --filter=<repo>\t limit to select distro/arch repo(s)\t\t\t ${filter[*]}"
    echo -e "  --output=<directory>\t the save location\t\t\t\t $outputDir"
    echo -e "  --tempdir=<directory>\t scratch area for temporary files\t\t $tempDir"
    echo -e "  --size=<megabytes>\t image file size for overlay\t\t\t (default: $imgSize)"
    echo -e "  --keep-new\t\t save the new files\t\t\t\t $savepkgs"
    echo -e "  --no-cache\t\t do not use mirror as base\t\t\t\t $nocache"
    echo -e "  --no-sign\t\t do not use GPG sign metadata (use external sign server)\t\t\t\t $nosign"
    echo -e "  --debug\t\t verbose output\t\t $debug"
    echo -e "  --clean\t\t un-mount stale overlayFS mountpoints\t\t $clean"
    echo

    if [[ -n $1 ]]; then
        echo "ERROR: $*"
        exit 1
    else
        exit 0
    fi
}

run_cmd() {
    echo
    echo ">>> $*" | fold -s
    time eval "$*"
}

run_rsync() {
    run_cmd rsync -av $*
}

preflight_checks() {
    # Minimum requirements
    kernelMajor=$(uname -r 2>/dev/null | awk -F '.' '{print $1}')
    pythonMajor=$(type -p python3 2>/dev/null)
    createRepo=$(type -p createrepo_c createrepo 2>/dev/null | awk NR==1)
    [[ $kernelMajor -gt 3 ]] || err "Kernel must be 4.x or newer for overlayFS"
    [[ $pythonMajor =~ "3" ]] || err "Python 3.x required for modularity"
    [[ -n $createRepo ]] || err "Missing depends for RPM repos"

    # FIXME
    userGroup=$(ls --color=none -ld $PWD 2>/dev/null | awk '{print $3":"$4}')

    # Cleanup previous runs
    rm -f -- "$fileManifest"
    clean_up

    # Create scratch area
    mkdir -p "$tempDir/tmp"
    cd "$tempDir/tmp" >/dev/null || err "unable to cd to $tempDir/tmp"

    # Pass-through
    if [[ -n $nocache ]]; then
        passthrough+=" --nocache "
    fi

    # Disable GPG signing
    if [[ -n $nosign ]]; then
        passthrough+=" --gpgkey=UNSIGNED "
    fi
}

package_metadata() {
    echo ":: Generate repo metadata"
    repos=$(find ${active[@]} -mindepth 2 -maxdepth 2 -type d 2>/dev/null | rev | sed -e 's|/|\t|' -e 's|/|\t|' | rev | sort -k2,3 -r | uniq -f1 | sed 's|\t|/|g')
    echo $repos
    for path in $repos; do
        unset subpath moreArgs unknownDistro skipNext
        subpath=$(echo $path | awk -F "/" '{print $(NF-1)"/"$(NF)}')
        rpmFormat=$(ls $path/*.rpm 2>/dev/null | awk NR==1)
        debFormat=$(ls $path/*.deb 2>/dev/null | awk NR==1)
        echo

        if [[ -n "$filter" ]]; then
            if [[ ! " ${filter[@]} " =~ " $subpath " ]]; then
                skipNext=1
            fi
        fi

        subdist=$(dirname "$subpath" 2>/dev/null | grep -v "^\.$")
        subarch=$(basename "$subpath" 2>/dev/null | grep -v "^\.$")
        if [[ -z "$subdist" ]] || [[ -z "$subarch" ]]; then
            unknownDistro=1
        elif [[ "$subdist" == "$subarch" ]]; then
            unknownDistro=1
        else
            moreArgs=" --distro=$subdist --arch=$subarch "
        fi

        if [[ -n "$skipNext" ]]; then
            echo "==> skipping repo: $subpath"
        elif [[ -n "$rpmFormat" ]]; then
            unset rpmFormat
            echo "==> rpm_metadata $passthrough $moreArgs --input $mountDir --mirror $mirror --repo $subpath"
            time $rpmMetadata $passthrough $moreArgs --input "$mountDir" --mirror "$mirror" --repo "$subpath"
            echo
        elif [[ -n "$debFormat" ]]; then
            unset debFormat
            echo "==> deb_metadata $passthrough $moreArgs --input $mountDir --mirror $mirror --repo $subpath"
            time $debianMetadata $passthrough $moreArgs --input "$mountDir" --mirror "$mirror" --repo "$subpath"
            echo
        else
            echo "==> skipping unimplemented format: $subpath $moreArgs"
        fi
    done
    echo
}

min_tempsize() {
    echo "==> Calculating scratch size"
    local depthTwo=$(find $@ -mindepth 2 -maxdepth 2 -type d 2>/dev/null | sort -r)
    unset sumLocal sumRemote
    for repoPath in $depthTwo; do
        local subdir=$(echo $repoPath | awk -F "/" '{print $(NF-1)"/"$(NF)}')
        echo -n "."
        local localSize=$(du -sc -BM ${repoPath}/repodata ${repoPath}/Packages* 2>/dev/null | tail -n 1 | awk -F "M" '{print $1}')
        local remoteSize=$(du -sc -BM ${mirror}/${subdir}/repodata ${mirror}/${subdir}/Packages* 2>/dev/null | tail -n 1 | awk -F "M" '{print $1}')
        sumLocal=$((sumLocal + localSize))
        sumRemote=$((sumRemote + remoteSize))
    done

    repoSum=$((sumLocal + sumRemote))
    echo

    # Powers of 2
    for n in $(seq 1 13); do
        powerTwo=$((2**n))
        if [[ $repoSum -le $powerTwo ]]; then
            break
        fi
    done

    # Sanity check
    if [[ $repoSum -gt $powerTwo ]]; then
        err "Power of 2 overflow detected (${repoSum}M > ${powerTwo}M, specify custom --size"
    fi

    echo ":: Optimal scratch size: ${repoSum}M -> ${powerTwo}M"
    imgSize=$((powerTwo + repoSum))
}

mount_tempfs() {
    echo ":: Create scratch filesystem: $scratch"
    echo ">>> dd if=/dev/zero of=$onetimeFS bs=1M count=${imgSize}"
    dd if=/dev/zero of="$onetimeFS" bs=1M count=${imgSize} || err "dd ${onetimeFS} ${imgSize}MB"
    mkfs -t ext4 -F "$onetimeFS" || err "mkfs.ext4"

    mkdir -p $scratch || err "mkdir -p $scratch"
    echo ">>> sudo mount -t ext4 $onetimeFS $scratch"
    sudo mount -t ext4 "$onetimeFS" "$scratch" || err "mount -t ext4 $onetimeFS $scratch"

    echo "userGroup == $userGroup"
    sudo chown -R $userGroup "$scratch" || err "chown $userGroup scratch"
    ls -l "$scratch"
    echo
}

mount_overlay() {
    echo ":: Overlay filesystems as layers: $mountDir"
    mkdir -p $mountDir || err "mkdir -p $mountDir"
    mkdir -p $scratch/{upper,workdir} || err "mkdir -p $scratch/{upper,workdir}"
    [[ -d "$scratch/upper" ]] || err "directory $scratch/upper does not exist"
    [[ -d "$scratch/workdir" ]] || err "directory $scratch/workdir does not exist"
    [[ -d "$mountDir" ]] || err "directory $mountDir does not exist"

    if [[ $rootless -eq 1 ]]; then
        [[ -n $FUSEOPTS ]] && FUSEOPTS="${FUSEOPTS},"
        echo ">>> fuse-overlayfs -o ${FUSEOPTS}lowerdir=${layers},upperdir=${scratch}/upper,workdir=${scratch}/workdir none $mountDir"
        fuse-overlayfs -o ${FUSEOPTS}lowerdir=${layers},upperdir=${scratch}/upper,workdir=${scratch}/workdir none $mountDir || err "mount -t overlay"
    else
        echo ">>> sudo mount -t overlay -o lowerdir=${layers},upperdir=${scratch}/upper,workdir=${scratch}/workdir none $mountDir"
        sudo mount -t overlay -o lowerdir=${layers},upperdir=${scratch}/upper,workdir=${scratch}/workdir none $mountDir || err "mount -t overlay"
    fi
    echo
}

save_new_metadata() {
    echo ":: Saving metadata to $outputDir"
    # Metadata
    run_rsync "${scratch}/upper"/ "$outputDir"
    echo
}

save_new_packages() {
    echo ":: Saving packages to $outputDir"
    # Packages
    repos=$(find ${active[@]} -mindepth 2 -maxdepth 2 -type d 2>/dev/null | sort)
    for path in $repos; do
        subpath=$(echo $path | awk -F "/" '{print $(NF-1)"/"$(NF)}')
        if [[ -n "$filter" ]]; then
            if [[ ! " ${filter[@]} " =~ " $subpath " ]]; then
                continue
            fi
        fi

        mkdir -p "$outputDir/${subpath}"/
        run_rsync --include="*.deb" --include="*.rpm" --include="*.repo" --include="*.pin" --include="*.pub" --include="*.json" --exclude="*" "${path}"/ "$outputDir/${subpath}"/

        if [[ -f "${path}/precompiled/index.html" ]]; then
            run_rsync --include="*.html" --exclude="*" "${path}/precompiled"/ "$outputDir/${subpath}/precompiled"/
        fi
    done
    echo
}


# Overrides
while [[ $1 =~ ^-- ]]; do
    # Filter repos
    if [[ "$1" =~ "--filter=" ]]; then
        include=$(echo "$1" | awk -F '=' '{print $2}')
        filter+=("$include")
    elif [[ "$1" =~ ^--filter$ ]]; then
        shift; filter+=("$1")
    # Output directory
    elif [[ "$1" =~ "--output=" ]]; then
        outputDir=$(echo "$1" | awk -F '=' '{print $2}')
    elif [[ "$1" =~ ^--output$ ]]; then
        shift; outputDir="$1"
    # Scratch directory
    elif [[ $1 =~ "tempdir=" ]] || [[ $1 =~ "workdir=" ]]; then
        tempDir=$(echo "$1" | awk -F "=" '{print $2}')
    elif [[ $1 =~ ^--tempdir$ ]] || [[ $1 =~ ^--workdir$ ]]; then
        shift; tempDir="$1"
    # Source of truth
    elif [[ $1 =~ "mirror=" ]]; then
        mirror=$(readlink -m $(echo "$1" | awk -F "=" '{print $2}'))
    elif [[ $1 =~ ^--mirror$ ]]; then
        shift; mirror=$(readlink -m "$1")
    # Specify image size
    elif [[ "$1" =~ "--size=" ]]; then
        customSize=$(echo "$1" | awk -F '=' '{print $2}')
        imgSize="$customSize"
    elif [[ "$1" =~ --size$ ]]; then
        shift; customSize="$1"
        imgSize="$customSize"
    # Save new packages
    elif [[ "$1" == "--keep-new" ]]; then
        savepkgs=1
    # Do not use source of truth
    elif [[ "$1" == "--no-cache" ]] || [[ "$1" == "--nocache" ]]; then
        nocache=1
    # Disable metadata signing
    elif [[ "$1" == "--no-sign" ]] || [[ "$1" == "--nosign" ]]; then
        nosign=1
    # Clean overlayFS mount
    elif [[ "$1" == "--clean" ]]; then
        clean=1
    # Verbose
    elif [[ "$1" == "--debug" ]]; then
        debug=1
    # Use FUSE implementation of overlayFS (does not require root permissions!)
    elif [[ "$1" == "--fuse" ]] || [[ -n $ROOTLESS ]] || [[ -n $FUSEOVERLAY ]]; then
        rootless=1
    # Usage
    elif [[ "$1" == "--help" ]]; then
        usage
    else
        echo -e "\nERROR: unknown parameter: $1\n"
        usage
    fi
    shift
done


ARGS=$(echo "$@" | sed 's| |\n\t\t\t\t\t\t\t\t\t |g')
fileManifest="${tempDir}/manifest.list"
onetimeFS="${tempDir}/tmp/upper.img"
scratch="${tempDir}/tmp/scratch"
mountDir="${tempDir}/tmp/overlay"

if [[ -n $debug ]]; then
    echo "temp: $tempDir"
    echo "mirror: $mirror"
    echo "input dirs: $@"
    echo "output: $outputDir"
fi

if [[ -n $clean ]]; then
    clean_up
    exit 0
fi

if [[ -n $nocache ]]; then
    mkdir -p "$tempDir/empty"
    mirror="$tempDir/empty"
fi

# Prepare overlayFS parameters
unset layers
for i in $@; do
    dir=$(readlink -m "$i")
    [[ -d "$dir" ]] &&
    layers+="${dir}:" &&
    active+=("$dir")
    shift
done
layers+="$mirror"

# Sanity checks
[[ -d $mirror ]] || usage "Must specify --mirror path to public snapshot [$mirror]"
[[ -d $dir ]] || usage "Must specify at least one directory to overlay [$dir]"
preflight_checks "$1"

# Sanity
if [[ -z $active ]]; then
    echo ":: No directories in overlay, bailing"
    exit 1
fi

if [[ -n "$optimize" ]] && [[ -z "$customSize" ]]; then
    min_tempsize ${active[@]}
fi

# Create scratch filesystem
if [[ -z $rootless ]]; then
    mount_tempfs
else
    echo "==> scratch: $scratch"
fi

# Overlay filesystems as layers
mount_overlay

# Generate repo metadata
package_metadata

# Save new packages to disk
if [[ -n $savepkgs ]]; then
    save_new_packages
fi

# Save metadata to disk
save_new_metadata

# Remove temp files
clean_up
[[ -d "$tempDir/empty" ]] &&
rmdir "$tempDir/empty"

true
### END ###
