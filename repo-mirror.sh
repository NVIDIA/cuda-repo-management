#!/usr/bin/env bash
# shellcheck disable=SC2001,SC2068,SC2086
# Copyright 2021, NVIDIA Corporation
# SPDX-License-Identifier: MIT

outputDir="$HOME/mirror"
baseURL="https://developer.download.nvidia.com/compute/cuda/repos"
version=("")

packages=1
metadata=1
directory=0

err() { echo "ERROR: $*"; exit 1; }

usage() {
    echo "USAGE: $0 <distro> <arch> [output] [version] [url]"
    echo
    echo " PARAMETERS:"
    echo -e "  --distro=[rhel8,ubuntu2004]\t Linux distro name"
    echo -e "  --arch=[x86_64,ppc64le,sbsa]\t CPU architecture"
    echo
    echo " OPTIONAL:"
    echo -e "  --dryrun\t\t skip downloading files"
    echo -e "  --follow\t\t also download files in subdirectories"
    echo -e "  --metadata\t\t only download metadata files"
    echo -e "  --packages\t\t only download package files"
    echo -e "  --output=<directory>\t save directory"
    echo -e "  --version=<11.4.2>\t filter results by string"
    echo -e "  --url=<name>\t\t override base URL to repository"
    echo
    err "$*"
}


file_downloader() {
    local inputURL="$1"
    local outFile="$2"
    curl -sL "$inputURL" --output "$outFile" -A "$(basename $0)"
}

precheck_files()
{
    stored=0
    queued=0
    # Pre-check packages
    for file in $@; do
        if [[ -f ${outputDir}/${distro}/${arch}/${file} ]]; then
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

    # Download packages
    for file in $@; do
        if [[ -f ${outputDir}/${distro}/${arch}/${file} ]]; then
            echo "[SKIP] $file"
        elif [[ -n $dryrun ]]; then
            echo "  -> $file"
            dirname=$(dirname "$file")
            mkdir -p "${outputDir}/${distro}/${arch}/${dirname}"
            touch "${outputDir}/${distro}/${arch}/${file}"
        else
            echo "  -> $file"
            dirname=$(dirname "$file")
            mkdir -p "${outputDir}/${distro}/${arch}/${dirname}"
            file_downloader "${baseURL}/${distro}/${arch}/${file}" "${outputDir}/${distro}/${arch}/${file}"
        fi
    done
}

copy_debs()
{
    repoDEB=("Release" "Release.gpg" "Packages" "Packages.gz")
    metaFiles=$(echo ${repoDEB[@]} | sed 's| |\n|g')
    gzipPath=$(echo "$metaFiles" | grep "\.gz")

    echo "==> Parsing $gzipPath"
    textBlocks=$(curl -sL "${baseURL}/${distro}/${arch}/${gzipPath}" --output - | gunzip -c -)
    packageFiles=$(echo "$textBlocks" | grep -E "$matching" | grep "^Filename: " | awk -F './' '{print $2}')

    if [[ -z "$packageFiles" ]]; then
        err "Unable to locate packages in repository for ${distro}/${arch}"
    fi

    download_files $packageFiles
}

copy_rpms()
{
    repoMD=$(curl -sL "${baseURL}/${distro}/${arch}/repodata/repomd.xml")
    metaFiles=$(echo "$repoMD" | grep "href=" | awk -F '"' '{print $2}' | sed '1irepodata/repomd.xml')
    gzipPath=$(echo "$metaFiles" | grep primary\.xml)

    echo "==> Parsing $gzipPath"
    primaryXML=$(curl -sL "${baseURL}/${distro}/${arch}/${gzipPath}" --output - | gunzip -c -)
    packageFiles=$(echo "$primaryXML" | grep -E "$matching" | grep "<location" | awk -F '"' '{print $2}')

    if [[ -z "$packageFiles" ]]; then
        err "Unable to locate packages in repository for ${distro}/${arch}"
    fi

    download_files $packageFiles
}

copy_subdir()
{
    local folder=$1
    dirHTML=$(curl -sL "${baseURL}/${distro}/${arch}/${folder}/index.html")
    echo "==> Parsing $folder"
    dirLinks=$(echo "$dirHTML" | sed 's|><|>\n<|g' | grep "<a href" | awk -F "'" '{print $2}' | grep -v -e "\.\.")
    subFiles=$(echo "$dirLinks" | grep -v -e "/$" -e "\.deb$" -e "\.rpm$" | sed "s|^|${folder}|" | grep -v "^${folder}$" | grep -E "$matching")

    if [[ -n "$subFiles" ]]; then
        download_files $subFiles
    else
        download_files ${folder}/index.html
    fi
}

copy_other()
{
    indexHTML=$(curl -sL "${baseURL}/${distro}/${arch}/index.html")
    echo "==> Parsing index"
    linkTags=$(echo "$indexHTML" | sed 's|><|>\n<|g' | grep "<a href" | awk -F "'" '{print $2}' | grep -v -e "\.\.")
    miscFiles=$(echo "$linkTags" | grep -v -e "/$" -e "\.deb$" -e "\.rpm$" | grep -E "$matching")
    subFolders=$(echo "$linkTags" | grep -e "/$" | grep "pre")

    if [[ -n "$metaFiles" ]] || [[ -n "$miscFiles" ]]; then
        download_files $metaFiles $miscFiles
    fi

    if [[ $directory == 1 ]]; then
        for subDir in $subFolders; do
            copy_subdir $subDir
        done
    fi
}


# Options
while [[ $1 =~ ^-- ]]; do
    # Do not download files
    if [[ $1 =~ "dryrun" ]] || [[ $1 =~ "dry-run" ]]; then
        dryrun=1
    # Follow subdirectories
    elif [[ $1 =~ "follow" ]]; then
        directory=1
    # Only metadata files
    elif [[ $1 =~ "metadata" ]]; then
        metadata=1
        unset packages
    # Only package files
    elif [[ $1 =~ "packages" ]]; then
        packages=1
        unset metadata
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
    # Download directory
    elif [[ $1 =~ "output=" ]]; then
        downloads=$(echo "$1" | awk -F "=" '{print $2}')
    elif [[ $1 =~ ^--output$ ]]; then
        shift; downloads="$1"
    # Base URL
    elif [[ $1 =~ "url=" ]]; then
        customURL=$(echo "$1" | awk -F "=" '{print $2}')
    elif [[ $1 =~ ^--url$ ]]; then
        shift; customURL="$1"
    # Version array
    elif [[ $1 =~ "version=" ]]; then
        version+=("$(echo $1 | awk -F '=' '{print $2}')")
    elif [[ $1 =~ ^--version$ ]]; then
        shift; version+=("$1")
    fi
    shift
done

[[ -n $distro ]] || usage "Must specify Linux distro name"
[[ -n $arch ]]   || usage "Must specify CPU architecture"

# Flatten version array
matching=$(echo "${version[@]}" | sed -e 's|^ ||' -e 's| $||' -e 's/ /|/g')

# Overrides
if [[ -n "$downloads" ]]; then
    outputDir="$downloads"
else
    echo ":: Saving to $outputDir"
fi

if [[ -n "$customURL" ]]; then
    baseURL="$customURL"
else
   echo ":: Scraping $baseURL"
fi


# Do mirroring
if [[ "$distro" =~ "fedora" ]] || [[ "$distro" =~ "rhel" ]] || [[ "$distro" =~ "sles" ]] || [[ "$distro" =~ "suse" ]]; then
    [[ $packages == 1 ]] && copy_rpms
    [[ $metadata == 1 ]] && copy_other
elif [[ "$distro" =~ "debian" ]] || [[ "$distro" =~ "ubuntu" ]]; then
    [[ $packages == 1 ]] && copy_debs
    [[ $metadata == 1 ]] && copy_other
else
    err "Unsupported distro"
fi

### END ###
