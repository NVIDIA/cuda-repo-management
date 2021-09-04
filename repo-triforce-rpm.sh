#!/usr/bin/env bash
# shellcheck disable=SC2002,SC2164,SC2012,SC2086,SC2155
# Copyright 2021, NVIDIA Corporation
# SPDX-License-Identifier: MIT

# CLI
workDir="$1"
mirror="$2"
mountDir="$3"
subpath="$4"
forpath="$5"

current=$(readlink -e "$(dirname $0)")
parentDir=$(dirname "$current")
genmodulespy="${parentDir}/genmodules.py"

fileManifest="${workDir}/manifest.list"
tempDir="${workDir}/tmp"
createrepoLog="${tempDir}/createrepo.log"
gpgkeyName="" # set this to shortname for GPG keypair

err() {
    echo "ERROR: $*"
    exit 1
}

compare_file() {
    local file1=$(md5sum "$mirror/$2/$3" | awk '{print $1}')
    local file2=$(md5sum "$1/$2/$3" | awk '{print $1}')
    echo ":: [file1] $mirror/$2/$3: $file1"
    echo ":: [file2] $1/$2/$3: $file2"
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

    rpms=$(find "$parent/$subpath" -mindepth 1 -maxdepth 1 -type d -name "repodata" | sort)
    for repo in $rpms; do
        echo "==> $repo"
        get_checksum "$repo"
    done
}

compare_md5sum() {
    [[ -d "$1" ]] || err "USAGE: compare_md5sum() <dir1> [dir2] [subpath] [format]"
    [[ -d "$2" ]] || err "USAGE: compare_md5sum() [dir1] <dir2> [subpath] [format]"
    [[ -n "$3" ]] || err "USAGE: compare_md5sum() [dir1] [dir2] <subpath> [format]"
    [[ -n "$4" ]] || err "USAGE: compare_md5sum() [dir1] [dir2] [subpath] <format>"

    if [[ "$4" == "rpm" ]]; then
        file1=$(rpm_md5sum "$1" "$3")
        file2=$(rpm_md5sum "$2" "$3")
    else
        echo "WARNING: unknown package format: $4"
        return 1
    fi

    echo "$file1"
    echo "---"
    echo "$file2"
    echo "---------"

    two_way=$(comm -1 -3 <(echo "$file1" | sort) <(echo "$file2" | sort) | grep -v "^==>" | sort -k2)
    echo "$two_way"

    # Needed to flush CDN cache
    for line in $(echo "$two_way" | awk '{print $2}'); do
        if [[ "$4" == "rpm" ]]; then
            echo "${subpath}/repodata/${line}" >> "$fileManifest"
        fi
    done

    diff_count=$(echo "$two_way" | wc -l)
    [[ $diff_count -gt 1 ]] || err "metadata unchanged"
    echo ":: $diff_count metadata file(s) added or modified"
}

rpm_metadata() {
    local donor="$1"
    local parent="$2"
    local subpath="$3"
    repomd="repodata/repomd.xml"
    oldPWD="$PWD"

    cd "$parent"/"$subpath" || err "unable to cd to $parent / $subpath"
    #echo ":: Cache hit saves ~20 minutes using --update-md-path <dir> and --update flags"

    #FIXME WAR for overlayFS invalid cross-device link
    echo ":: WAR for overlayFS invalid cross-device link"
    mkdir old
    echo ">>> mv repodata old/repodata"
    mv repodata old/repodata

    #
    # NOTE this saves about 20 minutes!
    # --update-md-path <dir> and --update flags
    echo ">>> createrepo_c -v --outputdir old --update --database $PWD"
    createrepo_c -v --update-md-path old --update --database "$PWD" 2>&1 | tee "$createrepoLog"
    [[ ${PIPESTATUS[0]} -eq 0 ]] || err "createrepo_c failed"
    echo

    # Needed to flush CDN cache
    pkg_cache=$(cat "$createrepoLog" 2>/dev/null | grep "CACHE HIT" | awk '{print $NF}')
    pkg_modify=$(cat "$createrepoLog" 2>/dev/null | grep "metadata are obsolete" | awk '{print $2}')
    pkg_list=$(find "$PWD" -maxdepth 1 -type f -name "*.rpm" 2>/dev/null | awk -F '/' '{print $NF}')
    pkg_diff=$(comm -1 -3 <(echo "$pkg_cache" | sort) <(echo "$pkg_list" | sort))
    for pkg in $(echo -e "${pkg_diff}\n${pkg_modify}" | sort -u); do
        echo ":: ${subpath}/${pkg}"
        echo "${subpath}/${pkg}" >> "$fileManifest"
    done
    rm "$createrepoLog"
    echo

    # Modularity
    if [[ "$2" =~ "rhel8" ]] || [[ "$2" =~ fedora[3-9] ]]; then
        # Driver streams expect driver packages present
        if [[ -n "$mirrorDriver" ]] || [[ -n "$pathDriver" ]]; then
            echo "%%%%%%%%%%%%%%%%%%"
            echo "%%% Modularity %%%"
            echo "%%%%%%%%%%%%%%%%%%"

            echo ">>> python3 $genmodulespy $PWD modules.yaml"
            python3 $genmodulespy "$PWD" modules.yaml || err "./genmodules.py $PWD modules.yaml"
            [[ -f "modules.yaml" ]] || err "modules.yaml not found at $PWD"
            echo

            echo ">>> modifyrepo_c modules.yaml $PWD/repodata"
            modifyrepo_c modules.yaml $PWD/repodata || err "modifyrepo_c modules.yaml $PWD/repodata"
            echo
        fi
    fi

    echo ":: Sanity check for repomd.xml"
    compare_file "$parent" "$subpath" "$repomd" && err "expected new metadata"
    echo

    echo ">>> gpg --batch --yes -a -u ${gpgkeyName} --detach-sign --personal-digest-preferences SHA512 $repomd"
    gpg --batch --yes -a -u ${gpgkeyName} --detach-sign --personal-digest-preferences SHA512 "$repomd" || err "repomd.xml.asc failed"
    echo ">>> gpg --batch --yes -a --export ${gpgkeyName} > ${repomd}.key"
    gpg --batch --yes -a --export ${gpgkeyName} > ${repomd}.key || err "repomd.xml.key failed"
    echo

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

    compare_md5sum "$donor" "$mountDir" "$subpath" "rpm"
    echo
}

[[ -f "$genmodulespy" ]] || err "genmodules.py not found at $genmodulespy"
mirrorDriver=$(ls ${mirror}/${subpath}/nvidia-driver* 2>/dev/null | awk NR==1)
pathDriver=$(ls ${forpath}/nvidia-driver* 2>/dev/null | awk NR==1)

rm -f "$createrepoLog"
rpm_metadata "$mirror" "$mountDir" "$subpath"
