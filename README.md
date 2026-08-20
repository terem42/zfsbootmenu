[![ZFSBootMenu Logo](media/logos/Logo_TextOnly_Color.svg)](https://zfsbootmenu.org)

[![Build Check](https://github.com/zbm-dev/zfsbootmenu/actions/workflows/build.yml/badge.svg?branch=master)](https://github.com/zbm-dev/zfsbootmenu/actions/workflows/build.yml) [![Documentation Status](https://readthedocs.org/projects/zfsbootmenu/badge/?version=latest)](https://docs.zfsbootmenu.org/en/latest/?badge=latest) [![Latest Packaged Version(s)](https://repology.org/badge/latest-versions/zfsbootmenu.svg)](https://repology.org/project/zfsbootmenu/versions)

ZFSBootMenu is a Linux bootloader that attempts to provide an experience similar to FreeBSD's bootloader. By taking advantage of ZFS features, it allows a user to have multiple "boot environments" (with different distributions, for example), manipulate snapshots before booting, and, for the adventurous user, even bootstrap a system installation via `zfs recv`.

In essence, ZFSBootMenu is a small, self-contained Linux system that knows how to find other Linux kernels and initramfs images within ZFS filesystems. When a suitable kernel and initramfs are identified (either through an automatic process or direct user selection), ZFSBootMenu launches that kernel using the `kexec` command.

![screenshot](/media/v2.3.0-multi-be.png)

## Remote SSH Access

This fork includes enhanced remote SSH access support for headless servers and cloud environments:

### ⚠️ Breaking Changes from Upstream

| Change | Before (upstream) | After (this fork) |
|--------|-------------------|-------------------|
| **SSH Port** | 222 | **22** (standard SSH port) |
| **SSH Timeout** | Indefinite wait | **30 seconds** (configurable) |
| **Auto-launch** | Manual `zfsbootmenu` command | **Automatic** on SSH login |
| **Network Config** | `ip=single-dhcp` (first interface only) | `ip=dhcp` (all interfaces) |

### Critical Fixes

- **RFC 3442 DHCP Fix**: Fixes dracut init loop on providers like Hetzner that use classless static routes
  - Resolves `integer expression expected` and `shift count out of range` errors
  - Patched `parse_option_121()` function with proper argument validation

### Features

- **SSH Connection Timeout**: Wait for SSH login before auto-boot (default: 30 seconds)
- **Multi-NIC Support**: DHCP on all interfaces by default, or specify by MAC address
- **RFC 3442 DHCP Fix**: Robust handling of classless static routes (works with Hetzner and similar providers)
- **Race Condition Prevention**: Console waits when SSH user is connected

### Quick Start

```bash
# Build ZBM with SSH support (uses DHCP on all interfaces)
./contrib/remote-ssh-build.sh

# Or specify a specific NIC by MAC address
NET_MAC=aa:bb:cc:dd:ee:ff ./contrib/remote-ssh-build.sh

# Override SSH timeout (default 30s, 0 = indefinite)
SSH_TIMEOUT=60 ./contrib/remote-ssh-build.sh
```

### Kernel Command Line Parameters

| Parameter | Description |
|-----------|-------------|
| `zbm.ssh_timeout=N` | Wait N seconds for SSH login before auto-boot; `0` waits indefinitely; omit the parameter to skip the SSH wait entirely |
| `ip=dhcp` | Enable DHCP on all interfaces (default) |
| `ifname=eth0:<mac> ip=eth0:dhcp` | Use specific NIC by MAC address |

### Repacking Existing Images

Use `contrib/zbm-repack.sh` to add SSH keys to existing ZBM EFI or BIOS images:

```bash
sudo ./contrib/zbm-repack.sh -i vmlinuz.EFI -k ~/.ssh/authorized_keys
```

### Local Testing with QEMU/KVM

Use `contrib/remote-ssh-lab.sh` to boot a freshly built image in a local VM and
verify remote access before deploying to a real server. The VM is headless, so
SSH is the only way in:

```bash
cd /path/to/build/dir            # the directory used for remote-ssh-build.sh
/path/to/contrib/remote-ssh-lab.sh          # then: ssh -p 2222 root@localhost
/path/to/contrib/remote-ssh-lab.sh -s       # with a serial console, to watch the boot
/path/to/contrib/remote-ssh-lab.sh -t 30    # override zbm.ssh_timeout for one boot
```

The same script tears the lab down again. `-k` stops the VM but keeps the images
and keys for the next boot; `-K` stops it and deletes everything the build and
lab scripts generated, including the dropbear host keys. It lists what it will
remove and prompts first (`-y` skips the prompt), leaves any file it did not
create alone, and only ever touches virtual machines belonging to this build
directory:

```bash
/path/to/contrib/remote-ssh-lab.sh -c       # reprint the ssh command to use
/path/to/contrib/remote-ssh-lab.sh -k       # stop the VM
/path/to/contrib/remote-ssh-lab.sh -K       # stop it and delete generated files
```

Booting prints a ready-to-paste `ssh` command, including `-i` for whichever
private key the image's `authorized_keys` actually accepts (found by comparing
key fingerprints) and the options that skip host-key caching, since the image's
dropbear host keys are regenerated on every build. `-c` reprints it later.
Nothing is ever written to `~/.ssh`.

The forwarded port is bound on all host interfaces, so the lab is also reachable
from other machines. Note that QEMU's user-mode DHCP server does not send RFC
3442 option 121; testing classless static routes requires a tap device and a
DHCP server configured to supply them (see `-N`).

On SELinux hosts, and when building with rootless podman, `remote-ssh-build.sh`
may need:

```bash
./contrib/remote-ssh-build.sh -M z -O -e -O DRACUT_NO_XATTR=1
```

### For more details, see:

- [Documentation](https://docs.zfsbootmenu.org)
- [Boot Environments and You: A Primer](https://docs.zfsbootmenu.org/en/latest/general/bootenvs-and-you.html)
- [Remote Access Guide](https://docs.zfsbootmenu.org/en/latest/general/remote-access.html)

### Join us on IRC

Come chat about ZFSBootMenu in [#zfsbootmenu on libera.chat](https://web.libera.chat/#zfsbootmenu)
