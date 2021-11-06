# cuda repo management

[![License](https://img.shields.io/badge/license-MIT-green.svg)](https://opensource.org/licenses/MIT-license) [![Contributing](https://img.shields.io/badge/Contributing-Developer%20Certificate%20of%20Origin-violet)](https://developercertificate.org)

## Overview

Scripts for managing Debian and RPM package repositories containing many files.


See [concept](#concept) and [metadata](#metadata) sections below.

## Table of Contents

- [Overview](#overview)
- [Deliverables](#deliverables)
- [Demo](#demo)
- [Usage](#usage)
  * [repo-overlay](#repo-overlay)
  * [repo-debian](#repo-debian)
  * [repo-rpm](#repo-rpm)
  * [repo-mirror](#repo-rpm)
- [Prerequisites](#prerequisites)
  * [Clone this git repository](#clone-this-git-repository)
  * [(Optional) fetch genmodules](#optional-fetch-genmodules)
  * [Install build dependencies](#install-build-dependencies)
- [Concept](#concept)
  * [OverlayFS](#overlayfs)
  * [Caching strategy](#caching-strategy)
- [Metadata](#metadata)
  * [Debian](#debian)
  * [RPM](#rpm)
- [Related](#related)
  * [Precompiled kmod](https://github.com/NVIDIA/yum-packaging-precompiled-kmod)
  * [Tarball and Zip Deliverables](https://github.com/NVIDIA/build-system-archive-import-examples)
- [See also](#see-also)
  * [RHEL driver](https://github.com/NVIDIA/yum-packaging-nvidia-driver)
  * [Ubuntu driver](https://github.com/NVIDIA/ubuntu-packaging-nvidia-driver)
  * [SUSE driver](https://github.com/NVIDIA/zypper-packaging-nvidia-driver)
- [Contributing](#contributing)


## Deliverables

This repo contains scripts to generate repository metadata for **Debian** and **RPM** packages:


* `apt`-based distros (**Debian** or **Ubuntu**)
 ```shell
 - Packages
 - Packages.gz
 - Release
 - Release.gpg
 ```

* `dnf`-based distros (**RHEL** >= 8 or **Fedora** >= 29)
> _note_: modules.yaml requires `genmodules.py`

 ```shell
 - repodata/repomd.xml
 - repodata/repomd.xml.asc
 - repodata/repomd.xml.key
 - repodata/${sha256}-modules.yaml.gz
 - repodata/${sha256}-primary.xml.gz
 - repodata/${sha256}-primary.sqlite.bz2
 - repodata/${sha256}-filelists.xml.gz
 - repodata/${sha256}-filelists.sqlite.bz2
 - repodata/${sha256}-other.xml.gz
 - repodata/${sha256}-other.sqlite.bz2
 ```

* `yum`-based distros (**RHEL** == 7) and
`zypper`-based distros (**openSUSE** or **SLES**)
 ```shell
 - repodata/repomd.xml
 - repodata/repomd.xml.asc
 - repodata/repomd.xml.key
 - repodata/${sha256}-primary.xml.gz
 - repodata/${sha256}-primary.sqlite.bz2
 - repodata/${sha256}-filelists.xml.gz
 - repodata/${sha256}-filelists.sqlite.bz2
 - repodata/${sha256}-other.xml.gz
 - repodata/${sha256}-other.sqlite.bz2
 ```


## Demo

- Coming soon


## Prerequisites

### Clone this git repository

```shell
git clone https://github.com/NVIDIA/cuda-repo-management
cd cuda-repo-management
```

### (Optional) fetch genmodules

> _note_: [genmodules.py](https://github.com/NVIDIA/yum-packaging-precompiled-kmod/blob/main/genmodules.py
) is needed for generating modularity streams for NVIDIA driver packages

```shell
wget https://raw.githubusercontent.com/NVIDIA/yum-packaging-precompiled-kmod/main/genmodules.py
```

### Install build dependencies

```shell
# RPM repos
yum install createrepo_c python3
# Debian repos
yum install dpkg-dev
# OverlayFS
yum install e2fsprogs rsync
# Misc that should already be installed
yum install bash coreutils util-linux gawk sed findutils file gzip
```


## Usage

### repo-overlay
Update multiples repos at once using OverlayFS to layer directories

```shell
./repo-overlay.sh --mirror=path/to/snapshot (--output=path/to/save) (--tempdir=path/to/workdir) path/to/repos
> ex: time ./repo-overlay.sh --mirror=/data/snapshot
```

### repo-debian
Generate Debian package repository metadata using `bash` and `dpkg`

```shell
./repo-debian.sh --mirror=path/to/snapshot --input=path/to/repos --repo=$distro/$arch
> ex: time ./repo-debian.sh --mirror=/data/snapshot --input=$HOME/repos --repo=ubuntu1804/x86_64
```

### repo-rpm
Generate RPM package repository metadata using `createrepo_c`

```shell
./repo-rpm.sh --mirror=path/to/snapshot --input=path/to/repos --repo=$distro/$arch
> ex: time ./repo-rpm.sh --mirror=/data/snapshot --input=$HOME/repos --repos=rhel8/sbsa
```

### repo-mirror
Download Debian or RPM packages from an existing repository

```shell
./repo-mirror.sh --distro=$distro --arch=$arch (--version=$version) (--url=$repository) (--dryrun)
> ex: ./repo-mirror.sh --output=/data/snapshot --distro=sles15 --arch=x86_64
```


## Concept

Package managers do not scan repository directories (often served via HTTP/HTTPS), so from `apt`/`dnf`/`yum`/`zypper`'s perspective whether a package exists or not, is defined by pre-generated [metadata](#metadata) manifests. These metadata files provide Debian or RPM package availability information, which is used to resolve dependencies and for the selected files, determine the URLs to download.

Adding new packages to a repository requires re-generating this metadata. Using tools such as `apt-ftparchive` or `createrepo_c`, the full set of packages must be present in a single directory. This presents logistical challenges that involve copying thousands of large files around. Moreover, it lacks an elegant "undo" mechanism for iterative software development processes such as CI/CD pipelines.

### OverlayFS

Union file-systems such as OverlayFS, allow temporary overlapping of directory hierarchies using mount points. These mounts can cross file-system boundaries and utilize copy-on-write (COW). In other words, non-destructive repository merges that can be rolled back with `umount` without the need for redundant file copying.

The mount syntax is layered right-to-left, with read-only (RO) lower layers, and one read-write (RW) upper layer.

```shell
sudo mount -t overlay -o \
     lowerdir=${layer3}:${layer2}:${layer1},\
     upperdir=${layer4}/upper,\
     workdir=${layer4}/workdir \
     none \
     /mnt/overlayfs
```

### Caching strategy

Generating repository metadata for thousands of packages is CPU intensive and thus can take a very long time. Rather than building from scratch each time, old metadata can be re-used to reduce the workload.

#### Append-only
The `repo-debian.sh` script scans each Debian package in the directory, recording the key-value pair of filename and size (in bytes), to a variable. Then it parses `Packages.gz` for filename and size (in bytes) key-value pair and saves it to another variable. The two variables are compared using the `comm` command, which eliminates the duplicate entries. The remaining packages are processed using a combination of `dpkg -I`, `du`, and `md5sum`/`sha1sum`/`sha256sum`/`sha512sum`.

#### repodata
The `createrepo_c` command has an `--update` parameter to utilize existing RPM repository metadata in the `repodata/` directory. This prints "CACHE HIT" when cache is successfully applies and "metadata are obsolete" when it detects a package  mismatch requiring regenerating this data.

A wrinkle when this is used with OverlayFS is the `repodata/` directory will only be available in the lower layer, as indicated by the error message "invalid cross-device link". The solution is to create a "write" operation, by moving the directory and then passing `--update-md-path` to specify the new location to scan for `repodata/`.


## Metadata

A brief explanation of the format and contents of these repository metadata files.

### Debian

The `apt`/`apt-get` package manager looks for `${repo}/InRelease` and `${repo}/Release` files as its entry-point. This contains a timestamp, repository flag options, and a list of package manifest files. For the latter filename, size in bytes, MD5sum, SHA1sum, and SHA256sum hashes are provided.

#### Release

The package manager compares the information found in `Release` with `Packages` to determine if there is corruption or tampering. Additionally the `Release` file is signed with a public-private GPG key pair and signature is detached as `Release.gpg`. This effectively signs the entire Debian package repository and requires clients to import the public GPG key to validate authenticity.

```shell
Origin: <Organization>
Label: <Repository Name>
Architecture: <x86_64|ppc64el|sbsa|cross-linux-sbsa>
Date: $(date -R --utc)
MD5Sum:
 $md5                $bytes Packages
 $md5                $bytes Packages.gz
SHA1:
 $sha1               $bytes Packages
 $sha1               $bytes Packages.gz
SHA256:
 $sha256             $bytes Packages
 $sha256             $bytes Packages.gz
Acquire-By-Hash: <no|yes>
```

The `Release` file references `Packages` and a gzipped copy `Packages.gz`

#### Packages.gz

Gzipped text file, containing blocks representing each package in the Debian repository. Blocks contain key-value pairs, such as `Package:`, `Version:`, and `Depends:`. For multi-line values (common for `Depends` and `Description`) start line with a space. Blocks are separated with an empty line.

```shell
Package: $name
Version: ${version}-${revision}
Architecture: <amd64|ppc64el|sbsa|all>
Priority: optional
Section: <$repotype>/<$category>
Maintainer: $user <$email>
Installed-Size: $extract_bytes
Depends: $packageA (>= $versionA), $packageB (>= $versionB), $packageC (>= $versionC)
Filename: ./${name}_${version}-${revision}_${arch}.deb
Size: $download_bytes
MD5sum: $md5
SHA1: $sha1
SHA256: $sha256
SHA512: $sha512
Description: What this package is used for.
 Prefix each additional line with a space. Longer description for search with `apt-cache`.
 Separate each package block with an empty line.

Package: ${packageA}
Version: ${versionA}-1
...

```

##### Beware, "here be dragons"

Some gotchas apply, for example the order of the package blocks affects dependency resolution. Chronological order (oldest → newest) release is recommended. Therefore if `repo-debian.sh` locates an existing `Packages.gz` manifest, it appends new blocks to the end.

Additionally, there is a convention to the order of the key-values, as generated by `dpkg`. Some unofficial package tools such as `CMake` do not follow this convention, which in some cases has lead to undocumented behavior. Again `repo-debian.sh` tries to follow this convention as closely as possible.


_ _ _


### RPM

The `yum`/`dnf` and `zypper` package managers look for a `${repo}/repodata/repomd.xml` file as its entry-point. This contains a list of package manifest files (SHA256-prefixed). Each `<data>` XML tag contains the unique filename, size in bytes, timestamp, and SHA256sum hash (both compressed and extracted).

The package manager uses this XML file to determine the locations of `primary.{xml.gz,sqlite.bz2}`, `filelists.{xml.gz,sqlite.bz2}`, `other.{xml.gz,sqlite.bz2}`, and optionally `modules.yaml.gz`. To be more CDN friendly, these RPM metadata files are prefixed with their `SHA256` hash, such that the filename is unique, each time its contents have been modified.

#### repomd.xml

The `repomd.xml` file is signed with a public-private GPG key pair and signature is detached as `repomd.xml.asc`. Individual RPM packages must be signed but this is an additional layer to sign the RPM package repository metadata and requires clients to import the public GPG key (`repomd.xml.key`) to validate authenticity.

```shell
<?xml version="1.0" encoding="UTF-8"?>
<repomd xmlns=".../metadata/repo" xmlns:rpm=".../metadata/rpm">
  <revision>$epoch</revision>
  <data type="primary">
    <checksum type="sha256">$SHA256</checksum>
    <open-checksum type="sha256">$extract_SHA256</open-checksum>
    <location href="repodata/${SHA256}-primary.xml.gz"/>
    <timestamp>$epoch</timestamp>
    <size>$bytes</size>
    <open-size>$extract_bytes</open-size>
  </data>
  <data type="filelists">...</data>
  <data type="other">...</data>
  <data type="primary_db">...</data>
  <data type="filelists_db">...</data>
  <data type="other_db">
    <checksum type="sha256">$SHA256</checksum>
    <open-checksum type="sha256">$extract_SHA256</open-checksum>
    <location href="repodata/${SHA256}-other.sqlite.bz2"/>
    <timestamp>$epoch</timestamp>
    <size>$bytes</size>
    <open-size>$extract_bytes</open-size>
    <database_version>10</database_version>
  </data>
  <data type="modules">
    <checksum type="sha256">$SHA256</checksum>
    <open-checksum type="sha256">$extract_SHA256</open-checksum>
    <location href="repodata/${SHA256}-modules.yaml.gz"/>
    <timestamp>$epoch</timestamp>
    <size>$bytes</size>
    <open-size>$extract_bytes</open-size>
  </data>
</repomd>
```


#### primary.xml.gz

Gzipped XML file, containing `<package>` tags representing each package in the RPM repository. Contains package name, version, description, dependencies, SHA256 checksum, timestamp, size in bytes, etc. It is recommended to use `createrepo_c` to generate these files.

```shell
<?xml version="1.0" encoding="UTF-8"?>
<metadata xmlns=".../metadata/common" xmlns:rpm=".../metadata/rpm" packages="$pkgCount">
<package type="rpm">
  <name>$name</name>
  <arch>$arch</arch>
  <version epoch="1" ver="$version" rel="$release"/>
  <checksum type="sha256" pkgid="YES">$SHA256</checksum>
  <summary>Short description</summary>
  <description>Longer multi-line description</description>
  <time file="$epoch" build="$epoch"/>
  <size package="$bytes" installed="$bytes" archive="$bytes"/>
  <location href="${name}-${version}-${release}.${arch}.rpm"/>
  <format>
    <rpm:provides>
      <rpm:entry name="$SONAME()(64bit)"/>
    </rpm:provides>
    <rpm:requires>
      <rpm:entry name="$packageA"/>
    </rpm:requires>
  </format>
</package>
<package type="rpm">
  <name>$packageA</name>
...
</package>
</metadata>
```

#### modules.yaml

Multi-document YAML text file, with one document per modularity stream. Each stream contains timestamp, unique `context` identifier, list of package names available for that stream, and one or more modularity profiles. Streams are designated by branch (choose one) and profiles represent bundle use cases (install one or more sets). The `genmodules.py` script generates this metadata file if any packages containing the string `nvidia-driver` are present in the repository. It is then injected into `repomd.xml` using `modifyrepo_c` command.

```shell
document: modulemd
version: 2
data:
    name: $module
    stream: $stream
    version: $(date +%Y%m%d%H%M%S)
    context: $(echo $name $stream $version $distro | md5sum | cut -c -10)
    arch: $arch
    summary: Short description
    description: >-
        Long multi-line description.
    artifacts:
        rpms:
            - $packageA-$epoch:$version-$release.$arch
            - $packageB-$epoch:$version-$release.$arch
            - $packageC-$epoch:$version-$release.$arch
    profiles:
        $profile:
            description: Profile description
            rpms:
                - $packageA
                - $packageB
                - $packageC
...
---
document: modulemd
version: 2
data:
    name: $module
    stream: $streamB
```


## Related

### Precompiled kmod

  * [https://github.com/NVIDIA/yum-packaging-precompiled-kmod](https://github.com/NVIDIA/yum-packaging-precompiled-kmod)

### Tarball and Zip Deliverables

  * [https://github.com/NVIDIA/build-system-archive-import-examples](https://github.com/NVIDIA/build-system-archive-import-examples)


## See also

### RHEL driver

  * [https://github.com/NVIDIA/yum-packaging-nvidia-driver](https://github.com/NVIDIA/yum-packaging-nvidia-driver)

### Ubuntu driver

  * [https://github.com/NVIDIA/ubuntu-packaging-nvidia-driver](https://github.com/NVIDIA/ubuntu-packaging-nvidia-driver)

### SUSE driver

  * [https://github.com/NVIDIA/zypper-packaging-nvidia-driver](https://github.com/NVIDIA/zypper-packaging-nvidia-driver)


## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md)
