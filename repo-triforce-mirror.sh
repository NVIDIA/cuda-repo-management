#!/usr/bin/env bash
# shellcheck disable=SC2001,SC2068,SC2086

downloads="/dev/shm/mirror"
dryrun=1

baseURL="https://developer.download.nvidia.com/compute/cuda/repos"
distro="$1"
arch="$2"
version=("")

# Set defaults
[[ -z "$distro" ]] &&
distro="rhel8"

[[ -z "$arch" ]] &&
arch="x86_64"

err() { echo "ERROR: $*"; exit 1; }

precheck_files()
{
    stored=0
    queued=0

    # Pre-check packages
    for file in $@; do
        if [[ -f ${downloads}/${distro}/${arch}/${file} ]]; then
            stored=$((stored + 1))
        else
            queued=$((queued + 1))
        fi
    done

    if [[ $stored -gt 0 ]]; then
        echo ":: Found $stored local files"
    fi
}

download_files()
{
    precheck_files $@

    if [[ $queued -gt 0 ]]; then
        echo ":: Downloading $queued repo files"
    else
        echo ":: Up-to-date"
        return
    fi

    mkdir -p "$downloads"

    # Download packages
    for file in $@; do
        if [[ -f ${downloads}/${distro}/${arch}/${file} ]]; then
            echo "[SKIP] $file"
        elif [[ -n $dryrun ]]; then
            echo "  -> $file"
            dirname=$(dirname "$file")
            mkdir -p "${downloads}/${distro}/${arch}/${dirname}"
            touch "${downloads}/${distro}/${arch}/${file}"
        else
            echo "  -> $file"
            dirname=$(dirname "$file")
            mkdir -p "${downloads}/${distro}/${arch}/${dirname}"
            curl -sL "${baseURL}/${distro}/${arch}/${file}" --output "${downloads}/${distro}/${arch}/${file}"
        fi
    done
}

copy_debs()
{
    repoDEB=("Release" "Release.gpg" "Packages" "Packages.gz")
    metaFiles=$(echo ${repoDEB[@]} | sed 's| |\n|g')
    gzipPath=$(echo "$metaFiles" | grep "\.gz")

    echo "==> Parsing $gzipPath"
    primaryXML=$(curl -sL "${baseURL}/${distro}/${arch}/${gzipPath}" --output - | gunzip -c -)
    packageFiles=$(echo "$primaryXML" | grep -E "${version[@]}" | grep "^Filename: " | awk -F './' '{print $2}')

    if [[ -z "$packageFiles" ]]; then
        err "Unable to locate packages in repository for ${distro}/${arch}"
    fi

    download_files $packageFiles
}

copy_rpms()
{
    repoMD=$(curl -sL "${baseURL}/${distro}/${arch}/repodata/repomd.xml")
    metaFiles=$(echo "$repoMD" | grep "href=" | awk -F '"' '{print $2}')
    gzipPath=$(echo "$metaFiles" | grep primary\.xml)

    echo "==> Parsing $gzipPath"
    primaryXML=$(curl -sL "${baseURL}/${distro}/${arch}/${gzipPath}" --output - | gunzip -c -)
    packageFiles=$(echo "$primaryXML" | grep -E "${version[@]}" | grep "<location" | awk -F '"' '{print $2}')

    if [[ -z "$packageFiles" ]]; then
        err "Unable to locate packages in repository for ${distro}/${arch}"
    fi

    download_files $packageFiles
}

copy_other()
{
    indexHTML=$(curl -sL "${baseURL}/${distro}/${arch}/index.html")
    echo "==> Parsing index"
    miscFiles=$(echo "$indexHTML" | sed 's|><|>\n<|g' | grep "<a href" | awk -F "'" '{print $2}' | grep -v -e "\.\." -e "/$" -e "\.deb$" -e "\.rpm$")

    if [[ -z "$miscFiles" ]]; then
        err "Unable to locate misc files in repository for ${distro}/${arch}"
    fi

    download_files $metaFiles $miscFiles
}


# Do mirroring
if [[ "$distro" =~ "fedora" ]] || [[ "$distro" =~ "rhel" ]] || [[ "$distro" =~ "sles" ]] || [[ "$distro" =~ "suse" ]]; then
    copy_rpms
    copy_other
elif [[ "$distro" =~ "debian" ]] || [[ "$distro" =~ "ubuntu" ]]; then
    copy_debs
    copy_other
else
    err "Unsupported distro"
fi
