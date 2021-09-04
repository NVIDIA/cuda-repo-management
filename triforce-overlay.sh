#!/usr/bin/env bash
# shellcheck disable=SC2012,SC2068,SC2076,SC2086,SC2128,SC2199
# Copyright 2021, NVIDIA Corporation
# SPDX-License-Identifier: MIT

current=$(readlink -e "$(dirname $0)")
debianMetadata="${current}/repo-triforce-debian.sh"
rpmMetadata="${current}/repo-triforce-rpm.sh"

fileManifest="${PWD}/manifest.list"
outputDir="$PWD/out"
onlynewDir="$PWD/new"
tempDir="$PWD/tmp"
imgSize="2048"
onetimeFS="${tempDir}/upper.img"
scratch="${tempDir}/scratch"
mountDir="${tempDir}/overlay"

# Overrides
while [[ $1 =~ ^-- ]]; do
    # Output directory
    if [[ "$1" =~ "--output=" ]]; then
        outputDir=$(echo "$1" | awk -F '=' '{print $2}')
    elif [[ "$1" =~ "--filter=" ]]; then
        include=$(echo "$1" | awk -F '=' '{print $2}')
        filter+=("$include")
    # Server via HTTP
    elif [[ "$1" == "--http" ]]; then
        onlyhttp=1
    # Skip new package copy
    elif [[ "$1" == "--onlymeta" ]]; then
        onlymeta=1
    # Skip metadata generation
    elif [[ "$1" == "--onlyrecent" ]]; then
        onlyrecent=1
    # Skip metadata generation
    elif [[ "$1" == "--onlyhistory" ]]; then
        onlyhistory=1
    # Enable full file copy
    elif [[ "$1" == "--history" ]]; then
        fullhistory=1
    # Clean overlayFS mount
    elif [[ "$1" == "--clean" ]]; then
        clean=1
    fi
    shift
done

# First parameter is path to public snapshot
mirror="$1"
shift


clean_up() {
    cd /
    [[ -d "$mountDir" ]] && sudo umount "$mountDir"
    [[ -d "$mountDir" ]] && rmdir "$mountDir"
    [[ -d "$mountDir" ]] && sudo umount -l "$mountDir"
    [[ -d "$scratch" ]] && sudo umount "$scratch"
    [[ -d "$mountDir" ]] && rmdir "$mountDir"
    [[ -d "$scratch" ]] && rm -rf "$scratch"
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
    echo "USAGE: $0 [mirror] [dir] { [dir] ... }"
    echo "  --output=        output directory"
    echo "  --filter=        include repo"
    echo "  --http           HTTP server"
    echo "  --onlymeta       Save only the metadata"
    echo "  --onlyrecent"
    echo "  --onlyhistory"
    echo "  --history"
    echo "  --clean"
    clean_up
    exit 1
}

package_metadata() {
    echo ":: Generate repo metadata"
    repos=$(find ${active[@]} -mindepth 2 -maxdepth 2 -type d 2>/dev/null | sort -r)
    for path in $repos; do
        unset subpath mirrorDriver pathDriver skipNext
        subpath=$(echo $path | awk -F "/" '{print $(NF-1)"/"$(NF)}')
        rpmFormat=$(ls $path/*.rpm 2>/dev/null | awk NR==1)
        debFormat=$(ls $path/*.deb 2>/dev/null | awk NR==1)
        echo

        if [[ -n "$filter" ]]; then
            if [[ ! " ${filter[@]} " =~ " $subpath " ]]; then
                skipNext=1
            fi
        fi

        if [[ -n "$skipNext" ]]; then
            echo "==> skipping repo: $subpath"
        elif [[ -n "$rpmFormat" ]]; then
            unset rpmFormat
            echo "==> rpm_metadata $mountDir $subpath"
            time $rpmMetadata "$mountDir" "$subpath"
            echo
        elif [[ -n "$debFormat" ]]; then
            unset debFormat
            echo "==> deb_metadata $mirror $mountDir $subpath"
            time $debianMetadata "$mirror" "$mountDir" "$subpath"
            echo
        else
            echo "==> skipping unimplemented format: $subpath"
        fi
    done
    echo
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

    echo ">>> sudo mount -t overlay -o lowerdir=${layers},upperdir=${scratch}/upper,workdir=${scratch}/workdir none $mountDir"
    sudo mount -t overlay -o lowerdir=${layers},upperdir=${scratch}/upper,workdir=${scratch}/workdir none $mountDir || err "mount -t overlay"
    echo
}

save_new_metadata() {
    echo ":: Saving to $onlynewDir"
    # Metadata
    echo ">>> rsync -av ${scratch}/upper/ $onlynewDir"
    time rsync -av "${scratch}/upper"/ "$onlynewDir"
    echo
}

save_new_packages() {
    echo ":: Saving to $onlynewDir"
    # Packages
    repos=$(find ${active[@]} -mindepth 2 -maxdepth 2 -type d 2>/dev/null | sort)
    for path in $repos; do
        subpath=$(echo $path | awk -F "/" '{print $(NF-1)"/"$(NF)}')
        mkdir -p "$onlynewDir/${subpath}"/
        echo ">>> rsync -av --include='*.deb' --include='*.rpm' --include='*.repo' --include='*.pin' --include='*.pub' --include='*.json' --exclude='*' ${path}/ $onlynewDir/${subpath}/"
        time rsync -av --include="*.deb" --include="*.rpm" --include="*.repo" --include="*.pin" --include="*.pub" --include="*.json" --exclude="*" "${path}"/ "$onlynewDir/${subpath}"/

        if [[ -f "${path}/precompiled/index.html" ]]; then
            echo ">>> rsync -av --include='*.html' --exclude='*' ${path}/precompiled/ $onlynewDir/${subpath}/precompiled/"
            time rsync -av --include="*.html" --exclude="*" "${path}/precompiled"/ "$onlynewDir/${subpath}/precompiled"/
        fi
    done
    echo
}

save_full_history() {
    echo ":: Saving to $outputDir"
    repos=$(find ${active[@]} -mindepth 2 -maxdepth 2 -type d 2>/dev/null | sort)
    for path in $repos; do
        subpath=$(echo $path | awk -F "/" '{print $(NF-1)"/"$(NF)}')
        mkdir -p "$outputDir/${subpath}"/
        echo ">>> rsync --ignore-existing -av ${mountDir}/${subpath}/ $outputDir/${subpath}/"
        time rsync --ignore-existing -av "${mountDir}/${subpath}"/ "$outputDir/${subpath}"/
    done
    echo
}


# Minimum requirements
kernelMajor=$(uname -r 2>/dev/null | awk -F '.' '{print $1}')
pythonMajor=$(type -p python3 2>/dev/null)
createRepo=$(type -p createrepo_c 2>/dev/null)
[[ $kernelMajor -gt 3 ]] || err "Kernel must be 4.x or newer for overlayFS"
[[ $pythonMajor =~ "3" ]] || err "Python 3.x required for modularity and HTTP"
[[ -n $createRepo ]] || err "Missing depends for RPM repos"

# Sanity checks
if [[ $clean ]]; then clean_up; exit 0; fi
[[ -n $1 ]] || usage
[[ -d "$mirror" ]] || err "Mirror not found"
[[ -d "$outputDir" ]] && rm -rf "$outputDir"

# FIXME
userGroup=$(ls --color=none -ld $PWD 2>/dev/null | awk '{print $3":"$4}')

# Prepare overlayFS parameters
unset layers
for i in $@; do
    dir=$(readlink -e "$i")
    [[ -d "$dir" ]] &&
    layers+="${dir}:" &&
    active+=("$dir")
    shift
done
layers+="$mirror"

# Sanity
if [[ -z $active ]]; then
    echo ":: No directories in overlay, bailing"
    exit 1
fi

# Cleanup previous runs
mkdir -p "$tempDir"
cd "$tempDir" >/dev/null || err "unable to cd to $tempDir"
rm -f "$fileManifest"
clean_up


if [[ ! $onlyhistory ]]; then
    # Create scratch filesystem
    mount_tempfs

    # Overlay filesystems as layers
    mount_overlay
fi

if [[ $onlyhttp ]]; then
    # Serve overlay via HTTP
    cd "$mountDir" || err "unable to cd to $mountDir"
    python3 -m http.server 8080 || err "unable to launch http server on :8080"
elif [[ $onlymeta ]]; then
    # Generate repo metadata
    package_metadata

    # Save metadata to disk
    save_new_metadata
elif [[ $onlyrecent ]]; then
    # Save new packages to disk
    save_new_packages
elif [[ $onlyhistory ]]; then
    # Save full history to disk
    save_full_history
else
    ### Defaults
    # Generate repo metadata
    package_metadata

    # Save new packages to disk
    save_new_packages

    # Save metadata to disk
    save_new_metadata

    # Save full history to disk
    if [[ $fullhistory ]]; then
        save_full_history
    fi
fi

# Remove temp files
clean_up
