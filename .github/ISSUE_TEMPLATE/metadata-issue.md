---
name: Metadata issue
about: Reporting metadata issues with the CUDA repositories
title: 'Metadata issue with the CUDA repositories [CDN] '
labels: ''
assignees: kmittman

---

## Reporting metadata issues with the CUDA repositories

Is the CDN stale? Have you seen something like:
```shell
E: Failed to fetch *.deb  Hash Sum mismatch
   Hashes of expected file:
    - SHA512:$sha512, SHA256:$sha256, SHA1:$sha1 [weak], MD5Sum:$md5 [weak], Filesize:$bytes [weak]
   Hashes of received file:
    - SHA512:$sha512, SHA256:$sha256, SHA1:$sha1 [weak], MD5Sum:$md5 [weak], Filesize:$bytes [weak]
   Last modification reported: $(date -R --utc)
```

or

```shell
*.rpm: Downloading successful, but checksum doesn't match. 
Calculated: $sha256(sha256)  
Expected: $sha256(sha256)
```

### Please provide the following information in your comment:

1. The error message and the last command(s) run.

2. When was the `Release` (Debian) or `repomd.xml` (RPM) file last modified ?
   ```shell
   $ curl -I https://developer.download.nvidia.com/compute/cuda/repos/$distro/$arch/Release
   $ curl -I https://developer.download.nvidia.com/compute/cuda/repos/$distro/$arch/repodata/repomd.xml
   ```

3. The Linux distro and architecture. If cross-compiling or containerized, please mention that.
   ```shell
   $ cat /etc/os-release
   $ uname -a
   ```

4. Which NVIDIA repositories do you have enabled ?
    Do your `.list` / `.repo` files contain URLs using HTTP (port 80) or HTTPS (port 443) ?

5. Which geographic region is the machine located in ?

6. Which CDN edge node are you hitting ?

7.  Any other relevant environmental conditions (i.e. a specific Docker container image) ?
