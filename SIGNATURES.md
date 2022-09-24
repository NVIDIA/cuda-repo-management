# signatures

## Overview

How to verify RPM & Debian package and repo signatures

## Table of Contents

- [Overview](#overview)
- [Verify packages](#verify-packages)
  * [Debian packages](#debian-packages)
    - [Debian package method 1](#debian-package-method-1)
    - [Debian package method 2](#debian-package-method-2)
  * [RPM packages](#rpm-packages)
    - [RPM package method 1](#rpm-package-method-1)
    - [RPM package method 2](#rpm-package-method-2)
- [Verify repository](#verify-repository)
  * [Debian repo](#debian-repo)
    - [Debian repo method 1](#debian-repo-method-1)
    - [Debian repo method 2](#debian-repo-method-2)
    - [Debian repo method 3](#debian-repo-method-3)
  * [RPM repo](#rpm-repo)
    - [RPM repo method 1](#rpm-repo-method-1)
    - [RPM repo method 2](#rpm-repo-method-2)


## Verify packages

> NOTE: The recommended way to validate is to create a network repository and try installing the packages using the CLI apt-get/yum/dnf/zypper package manager.


### Debian packages

Un-packing the `_gpgbuilder` file from the archive reveals a message and signature. This requires some processing to validate.

##### Example 1
```shell
$ ar -p cuda-keyring_1.0-1_all.deb _gpgbuilder
```

<details>
  <summary>Expand</summary>

```shell
-----BEGIN PGP SIGNED MESSAGE-----
Hash: SHA512
 
Version: 4
Signer: cudatools <cudatools@nvidia.com>
Date: Fri Apr 22 09:56:53 2022
Role: builder
Files:
    3cf918272ffa5de195752d73f3da3e5e 7959c969e092f2a5a8604e2287807ac5b1b384ad 4 debian-binary
    326ddb43903cf2a9ba2559039d24e4c7 3b8302d1606c40e6645dff296e6118dd407fe6a3 900 control.tar.xz
    37991612ad00c6c8572666bbf5060e75 5498d47b1a177abdedc89ba2ec04e37d367951ae 1908 data.tar.xz
-----BEGIN PGP SIGNATURE-----
Version: GnuPG v2.0.22 (GNU/Linux)
 
iQIcBAEBCgAGBQJiYnvlAAoJEKS0aZY7+GPMg+MP/RIO2ZOS5zHfmMvn6WC5z370
CNchdGLHodvVHPgF75zw/dh7kcHWULfkV8WkuYMiJwhm0zGTOSx3TTxGiSI/5uEU
Wq4QZQmxCnWmvDfxNGuSs/NoeA2ZHHyMAswZvuIu35fc9uR9aPz7T3dhVw1Usuv7
ENKaHbt8NOOmh6osAGjrrDx1/LM9XmvjCvqxduDYFnq9yIJ/KCwxQLL8afzwLjym
qobpbWqcvzWyavZkXwI4AMpTZY+myGRA3CGpGnxKEmokHJC0XvT3eJRecRCzk/Ir
9msMyJJdU9ntNDF2Aup6uTaY7ACYgEo9W2IBUK7Y/YnbOK4YdYXdrTzzq6IerfK1
l/zCCdZ2951o6xPnZsRC3pb60n3RcpQehSkl5IVJXGA+IDFS50OtQKALuVVdCSf8
wuz1gEFQjIUkY3/QRh+7hw9AnJSQF9grtSZElzndnIhE3JczndA1/vGni1gfgJUI
c0NHXC+PUft+tNG/oahEE+NrXzUciyqlSeKGGniTvRoQDzlQfag9XcOkWJaSlJm7
bJZ1QCCRQPDzZp/aL+H7K+w3kUQibdrwrqpialB0jsDCsAE56e+4ptPddBHisFBG
FfkTpFNCAFFp+ylxUfyVaeGbDJ61YJSpLcICGTtbkQLCv08WOSWLzE2OdVnh94Pm
kGTdUd+T6SdLNP0p7L5A
=CaAY
-----END PGP SIGNATURE-----
```

</details>


_Setup a test environment_
```shell
setup='DEBIAN_FRONTEND=noninteractive apt-get install -y binutils gnupg wget ca-certificates'
docker run -it ubuntu:20.04 /bin/bash -c "apt-get update && $setup; bash"
baseurl="https://developer.download.nvidia.com/compute/cuda/repos"
wget $baseurl/ubuntu2004/x86_64/cuda-keyring_1.0-1_all.deb
wget $baseurl/ubuntu2004/x86_64/3bf863cc.pub
```

#### Debian package method 1
```shell
checksig_deb() { ar -p "$1" _gpgbuilder 2>&1 | gpg --openpgp --decrypt --no-auto-check-trustdb --batch --no-tty --status-fd 1 2>&1; }
checksig_deb *.deb
```

##### Example 2

```shell
$ checksig_deb() { ar -p "$1" _gpgbuilder 2>&1 | gpg --openpgp --decrypt --no-auto-check-trustdb --batch --no-tty --status-fd 1 2>&1; } 
$ checksig_deb cuda-keyring_1.0-1_all.deb
```

<details>
  <summary>Expand</summary>

```shell
[GNUPG:] PLAINTEXT 74 0
Version: 4
Signer: cudatools <cudatools@nvidia.com>
Date: Fri Apr 22 09:56:53 2022
Role: builder
Files:
3cf918272ffa5de195752d73f3da3e5e 7959c969e092f2a5a8604e2287807ac5b1b384ad 4 debian-binary
326ddb43903cf2a9ba2559039d24e4c7 3b8302d1606c40e6645dff296e6118dd407fe6a3 900 control.tar.xz
37991612ad00c6c8572666bbf5060e75 5498d47b1a177abdedc89ba2ec04e37d367951ae 1908 data.tar.xz
[GNUPG:] NEWSIG
gpg: Signature made Fri Apr 22 09:56:53 2022 UTC
gpg: using RSA key A4B469963BF863CC
[GNUPG:] ERRSIG A4B469963BF863CC 1 10 01 1650621413 9 -
```

Notice that it cannot validate the signature if the public key is not found

```shell
[GNUPG:] NO_PUBKEY A4B469963BF863CC
gpg: Can't check signature: No public key
```

then import the GPG public key

```shell
$ gpg --import 3bf863cc.pub
$ checksig_deb cuda-keyring_1.0-1_all.deb
```

```shell
[GNUPG:] PLAINTEXT 74 0
Version: 4
Signer: cudatools <cudatools@nvidia.com>
Date: Fri Apr 22 09:56:53 2022
Role: builder
Files:
3cf918272ffa5de195752d73f3da3e5e 7959c969e092f2a5a8604e2287807ac5b1b384ad 4 debian-binary
326ddb43903cf2a9ba2559039d24e4c7 3b8302d1606c40e6645dff296e6118dd407fe6a3 900 control.tar.xz
37991612ad00c6c8572666bbf5060e75 5498d47b1a177abdedc89ba2ec04e37d367951ae 1908 data.tar.xz
[GNUPG:] NEWSIG
gpg: Signature made Fri Apr 22 09:56:53 2022 UTC
gpg: using RSA key A4B469963BF863CC
[GNUPG:] KEY_CONSIDERED EB693B3035CD5710E231E123A4B469963BF863CC 0
[GNUPG:] SIG_ID Mx3zUme9SMeQ67oDvcbN449zOzQ 2022-04-22 1650621413
[GNUPG:] KEY_CONSIDERED EB693B3035CD5710E231E123A4B469963BF863CC 0
```

```shell
[GNUPG:] GOODSIG A4B469963BF863CC cudatools <cudatools@nvidia.com>
gpg: Good signature from "cudatools <cudatools@nvidia.com>" [unknown]
[GNUPG:] VALIDSIG EB693B3035CD5710E231E123A4B469963BF863CC 2022-04-22 1650621413 0 4 0 1 10 01 EB693B3035CD5710E231E123A4B469963BF86>
```

```shell
[GNUPG:] TRUST_UNDEFINED 0 pgp
gpg: WARNING: This key is not certified with a trusted signature!
gpg: There is no indication that the signature belongs to the owner.
Primary key fingerprint: EB69 3B30 35CD 5710 E231 E123 A4B4 6996 3BF8 63CC
[GNUPG:] VERIFICATION_COMPLIANCE_MODE 23
```

notice it now says "VALIDSIG" instead of "NO_PUBKEY"

```shell
$ gpg --delete-keys 3bf863cc
```

</details>


#### Debian package method 2
```shell
gpgbuilder=$(ar -p *.deb _gpgbuilder)
message=$(echo "$gpgbuilder" | sed -n '/-----BEGIN PGP SIGNATURE-----/q;p')
detached=$(echo "$gpgbuilder" | sed -n '/-----BEGIN PGP SIGNATURE-----/,$p')
gpg --verify <(echo "$detached") <(echo "$message")
```

##### Example 3

<details>
  <summary>Expand</summary>

```shell
$ gpgbuilder=$(ar -p cuda-keyring_1.0-1_all.deb _gpgbuilder)
$ message=$(echo "$gpgbuilder" | sed -n '/-----BEGIN PGP SIGNATURE-----/q;p')
$ detached=$(echo "$gpgbuilder" | sed -n '/-----BEGIN PGP SIGNATURE-----/,$p')
```

using process substitution

```shell
$ gpg --verify <(echo "$detached") <(echo "$message")
gpg: Signature made Fri Apr 22 09:56:53 2022 UTC
gpg:                using RSA key A4B469963BF863CC
gpg: Can't check signature: No public key
```

then import the GPG public key

```shell
$ gpg --import 3bf863cc.pub
$ gpg --verify <(echo "$detached") <(echo "$message")
gpg: Signature made Fri Apr 22 09:56:53 2022 UTC
gpg: using RSA key A4B469963BF863CC
gpg: BAD signature from "cudatools <cudatools@nvidia.com>" [unknown]
```

notice it now says "BAD signature" instead of "No public key"

```shell
$ gpg --delete-keys 3bf863cc
```

</details>


### RPM packages

Metadata is embedded on the outer layer of RPMs

_Setup a test environment_
```shell
docker run -it rockylinux:8 /bin/bash -c "dnf install -y wget; bash"
baseurl="https://developer.download.nvidia.com/compute/cuda/repos"
wget $baseurl/rhel8/x86_64/cuda-11-0-11.0.1-1.x86_64.rpm
wget $baseurl/rhel8/x86_64/D42D0685.pub
```

#### RPM package method 1

```shell
rpm -Kv *.rpm
```

##### Example 4

<details>
  <summary>Expand</summary>

```shell
$ rpm -Kv cuda-11-0-11.0.1-1.x86_64.rpm
cuda-11-0-11.0.1-1.x86_64.rpm:
    Header V4 RSA/SHA512 Signature, key ID d42d0685: NOKEY
    Header SHA1 digest: OK
    V4 RSA/SHA512 Signature, key ID d42d0685: NOKEY
    MD5 digest: O
```

then import the GPG public key

```shell
$ rpm --import D42D0685.pub
$ rpm -qa | grep gpg-pubkey
gpg-pubkey-d42d0685-62589a51
$ rpm -Kv cuda-11-0-11.0.1-1.x86_64.rpm
cuda-11-0-11.0.1-1.x86_64.rpm:
    Header V4 RSA/SHA512 Signature, key ID d42d0685: OK
    Header SHA1 digest: OK
    V4 RSA/SHA512 Signature, key ID d42d0685: OK
    MD5 digest: OK
```

notice it now says "OK"

```
$ rpm --erase "gpg-pubkey-d42d0685*"
```

</details>


#### RPM package method 2

```shell
rpm -qip *.rpm | grep ^Signature
```

##### Example 5

<details>
  <summary>Expand</summary>

```shell
$ rpm -qip cuda-11-0-11.0.1-1.x86_64.rpm | grep ^Signature
warning: cuda-11-0-11.0.1-1.x86_64.rpm: Header V4 RSA/SHA512 Signature, key ID d42d0685: NOKEY
Signature   : RSA/SHA512, Sat Apr 23 05:50:03 2022, Key ID 9cd0a493d42d0685
```

then import the GPG public key

```shell
$ rpm --import D42D0685.pub
$ rpm -qa | grep gpg-pubkey
gpg-pubkey-d42d0685-62589a51
$ rpm -qip cuda-11-0-11.0.1-1.x86_64.rpm | grep ^Signature
Signature : RSA/SHA512, Sat Apr 23 05:50:03 2022, Key ID 9cd0a493d42d0685
```

notice the warning error disappeared

</details>


## Verify repository

### Debian repo

There are several metadata files, with the "entry point" either `InRelease` (concatenated with signature) or `Release` and `Release.gpg` (detached signature).
Also there is `Packages` and `Packages.gz` (compressed) with contents that include the dependencies, descriptions, etc.

_Setup a test environment_
```shell
setup='DEBIAN_FRONTEND=noninteractive apt-get install -y binutils gnupg wget ca-certificates sudo'
docker run -it ubuntu:20.04 /bin/bash -c "apt-get update && $setup; bash"
baseurl="https://developer.download.nvidia.com/compute/cuda/repos"
wget $baseurl/ubuntu2004/x86_64/3bf863cc.pub
wget $baseurl/ubuntu2004/x86_64/Release
wget $baseurl/ubuntu2004/x86_64/Release.gpg
wget $baseurl/ubuntu2004/x86_64/InRelease
wget $baseurl/ubuntu2004/x86_64/cuda-ubuntu2004-keyring.gpg
```

#### Debian repo method 1

```shell
gpg --verify Release.gpg Release
```
validate the detached signature: `Release.gpg`

##### Example 6

<details>
  <summary>Expand</summary>

```shell
$ gpg --verify Release.gpg Release
gpg: Signature made Wed Aug 17 19:06:30 2022 UTC
gpg:                using RSA key A4B469963BF863CC
gpg: Can't check signature: No public key
```

then import the GPG public key

```shell
$ gpg --import 3bf863cc.pub
$ gpg --verify Release.gpg Release
gpg: Signature made Wed Aug 17 19:06:30 2022 UTC
gpg: using RSA key A4B469963BF863CC
gpg: Good signature from "cudatools <cudatools@nvidia.com>" [unknown]
gpg: WARNING: This key is not certified with a trusted signature!
gpg: There is no indication that the signature belongs to the owner.
Primary key fingerprint: EB69 3B30 35CD 5710 E231 E123 A4B4 6996 3BF8 63CC
```

</details>


#### Debian repo method 2

```shell
message=$(cat InRelease | sed -n '/-----BEGIN PGP SIGNATURE-----/q;p')
detached=$(cat InRelease | sed -n '/-----BEGIN PGP SIGNATURE-----/,$p')
gpg --verify <(echo "$detached") <(echo "$message")
```
validate the concatenated file: `InRelease`

##### Example 7

<details>
  <summary>Expand</summary>

```shell
$ message=$(cat InRelease | sed -n '/-----BEGIN PGP SIGNATURE-----/q;p')
$ detached=$(cat InRelease | sed -n '/-----BEGIN PGP SIGNATURE-----/,$p')
$ gpg --verify <(echo "$detached") <(echo "$message")
gpg: Signature made Wed Aug 17 19:06:30 2022 UTC
gpg:                using RSA key A4B469963BF863CC
gpg: Can't check signature: No public key
```

then import the GPG public key

```shell
$ gpg --verify <(echo "$detached") <(echo "$message")
gpg: Signature made Wed Aug 17 19:06:30 2022 UTC
gpg:                using RSA key A4B469963BF863CC
gpg: BAD signature from "cudatools <cudatools@nvidia.com>" [unknown]
$ gpg --delete-keys 3BF863CC
```

</details>


#### Debian repo method 3

```shell
echo "deb [signed-by=/usr/share/keyrings/*-archive-keyring.gpg] https://path/to/repo/ /" | sudo tee /etc/apt/sources.list.d/my-repo.list
sudo apt-get update
```
enable repo and refresh cached metadata

##### Example 8

<details>
  <summary>Expand</summary>

```shell
$ mv cuda-ubuntu2004-keyring.gpg /usr/share/keyrings/cuda-archive-keyring.gpg
$ echo "deb [signed-by=/usr/share/keyrings/cuda-archive-keyring.gpg] https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2004/x86_64/ /" | sudo tee /etc/apt/sources.list.d/cuda-ubuntu2004-x86_64.list
$ sudo apt-get update
```

</details>


### RPM repo

There are several metadata files under repodata/ with the "entry point" `repomd.xml` and `repomd.xml.asc` (detached signature). Also `repomd.xml.key` (GPG public key) is important.

These include checksums, bytes, and timestamps for fine-grain `*-primary.{xml.gz,sqlite.bz2}` and etc.

_Setup a test environment_
```shell
docker run -it rockylinux:8 /bin/bash -c "dnf install -y dnf-plugins-core wget sudo; bash"
mkdir repodata
baseurl="https://developer.download.nvidia.com/compute/cuda/repos"
(cd repodata && wget $baseurl/rhel8/x86_64/repodata/repomd.xml)
(cd repodata && wget $baseurl/rhel8/x86_64/repodata/repomd.xml.asc)
(cd repodata && wget $baseurl/rhel8/x86_64/repodata/repomd.xml.key)
```

#### RPM repo method 1

```shell
gpg --verify repodata/repomd.xml.asc repodata/repomd.xml
```

this is a manual way to validate detached signature

##### Example 9

<details>
  <summary>Expand</summary>

```shell
$ gpg --verify repodata/repomd.xml.asc repodata/repomd.xml
gpg: directory '/root/.gnupg' created
gpg: keybox '/root/.gnupg/pubring.kbx' created
gpg: Signature made Wed Aug 17 19:05:33 2022 UTC
gpg:                using RSA key 9CD0A493D42D0685
gpg: Can't check signature: No public key
```

then import the GPG public key

```shell
$ gpg --import repodata/repomd.xml.key
gpg: key 9CD0A493D42D0685: public key "cudatools <cudatools@nvidia.com>" imported
gpg: Total number processed: 1
gpg:               imported: 1
$ gpg --verify repodata/repomd.xml.asc repodata/repomd.xml
gpg: Signature made Wed Aug 17 19:05:33 2022 UTC
gpg:                using RSA key 9CD0A493D42D0685
gpg: Good signature from "cudatools <cudatools@nvidia.com>" [unknown]
gpg: WARNING: This key is not certified with a trusted signature!
gpg:          There is no indication that the signature belongs to the owner.
Primary key fingerprint: 610C 7B14 E068 A878 070D  A4E9 9CD0 A493 D42D 0685
 
$ gpg --delete-keys 3D42D0685
```

</details>


#### RPM repo method 2

```shell
sudo dnf config-manager --add-repo https://path/to/*.repo
sudo dnf install some-package
[...]
Importing GPG key 0x000000:
Userid : . . .
Fingerprint: . . .
From : /path/to/*.pub
Is this ok [y/N]:
```

this uses the package manager to install (recommended)

##### Example 10

<details>
  <summary>Expand</summary>

```shell
$ dnf config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/rhel8/x86_64/cuda-rhel8.repo
Adding repo from: https://developer.download.nvidia.com/compute/cuda/repos/rhel8/x86_64/cuda-rhel8.repo
$ dnf install libnvjpeg-11-0
[...]
Importing GPG key 0xD42D0685:
Userid : "cudatools <cudatools@nvidia.com>"
Fingerprint: 610C 7B14 E068 A878 070D A4E9 9CD0 A493 D42D 0685
From : https://developer.download.nvidia.com/compute/cuda/repos/rhel8/x86_64/D42D0685.pub
Is this ok [y/N]: y
```

</details>

