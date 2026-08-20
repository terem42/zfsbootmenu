#!/bin/bash
# vim: softtabstop=2 shiftwidth=2 expandtab

## REMOTE SSH LAB

# Boot an image built by remote-ssh-build.sh in a local QEMU/KVM virtual
# machine, so remote SSH access can be exercised without a real server.
#
# The VM is headless by default -- no display, no console -- so the only way
# in is SSH, exactly like a rented machine with no IPMI. A host port (2222 by
# default) is forwarded to the guest's dropbear on every host interface, so
# the lab is reachable both from this machine and from anywhere that can
# reach this host.

## USAGE

# Run from the same build directory used for remote-ssh-build.sh, or point
# $BUILD_DIR at it:
#
# ```
# ./remote-ssh-lab.sh              # headless; ssh -p 2222 root@localhost
# ./remote-ssh-lab.sh -s           # attach a serial console to this terminal
# ./remote-ssh-lab.sh -t 30        # override zbm.ssh_timeout for this boot
# ./remote-ssh-lab.sh -e           # boot the EFI bundle instead of kernel+initramfs
# ```
#
# The kernel command line baked into the image by remote-ssh-build.sh
# (ip=dhcp rd.neednet=1 zbm.ssh_timeout=N) applies as-is; -t overrides only
# the timeout, which is handy for exercising the SSH wait without rebuilding.

## SCRATCH DISK

# An empty disk image is attached so ZFSBootMenu has something to scan. It
# contains no pool, so ZBM will offer to initialize and then drop into its
# recovery shell -- enough to confirm remote access works. To test a real
# boot, attach a prepared pool image with -d instead.

## NOTE ON DHCP

# QEMU's built-in user-mode DHCP server never sends RFC 3442 option 121, so
# this lab does not exercise the classless-static-route path. Testing that
# requires a tap device with a DHCP server configured to hand out classless
# static routes (see docs or use -N to supply your own -netdev).

BUILD_DIR=$(realpath "${BUILD_DIR:-${PWD}}")
RS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SSH_PORT="${SSH_PORT:-2222}"
MEMORY="${MEMORY:-2048M}"
SMP="${SMP:-2}"

SERIAL=0
USE_EFI=0
TIMEOUT=""
EXTRA_DISK=""
NETDEV=""

usage() {
  cat <<-EOF
	Usage: $0 [OPTIONS] [FLAGS]

	  Boot a remote-ssh-build.sh image in a local KVM virtual machine

	OPTIONS
	  -d <image>
	     Attach this disk image instead of creating a scratch disk

	  -N <netdev>
	     Use this qemu -netdev argument instead of user-mode networking
	     (e.g. "tap,id=n0,ifname=zbmtap0,script=no,downscript=no")

	  -p <port>
	     Forward this host port to the guest's SSH port (default: ${SSH_PORT})

	  -t <seconds>
	     Append zbm.ssh_timeout=<seconds>, overriding the image default

	FLAGS
	  -e  Boot the EFI bundle (vmlinuz.EFI) instead of kernel+initramfs

	  -s  Attach a serial console to this terminal (quit qemu with Ctrl-A X)

	  -h  Show this message and exit
	EOF
}

while getopts "d:N:p:t:esh" opt; do
  case "${opt}" in
    d) EXTRA_DISK="${OPTARG}" ;;
    N) NETDEV="${OPTARG}" ;;
    p) SSH_PORT="${OPTARG}" ;;
    t) TIMEOUT="${OPTARG}" ;;
    e) USE_EFI=1 ;;
    s) SERIAL=1 ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

# zbm-builder writes its output to a "build" subdirectory of the build directory
RS_IMGDIR="${BUILD_DIR}/build"
[ -d "${RS_IMGDIR}" ] || RS_IMGDIR="${BUILD_DIR}"

if ((USE_EFI)); then
  RS_BUNDLE="${RS_IMGDIR}/vmlinuz.EFI"
  if [ ! -f "${RS_BUNDLE}" ]; then
    echo "ERROR: cannot find ${RS_BUNDLE}; run remote-ssh-build.sh first"
    exit 1
  fi

  # OVMF is needed to boot an EFI bundle; the copy in the source tree is used
  # when a system copy cannot be found
  RS_OVMF=""
  for _ovmf in "${RS_SCRIPT_DIR}/../testing/stubs/OVMF_CODE.fd" \
               /usr/share/edk2/ovmf/OVMF_CODE.fd \
               /usr/share/OVMF/OVMF_CODE.fd; do
    [ -f "${_ovmf}" ] && RS_OVMF="${_ovmf}" && break
  done

  if [ -z "${RS_OVMF}" ]; then
    echo "ERROR: cannot find OVMF firmware needed to boot an EFI bundle"
    exit 1
  fi

  BFILES=( -bios "${RS_OVMF}" -kernel "${RS_BUNDLE}" )
else
  RS_KERNEL="${RS_IMGDIR}/vmlinuz-bootmenu"
  RS_INITRD="${RS_IMGDIR}/initramfs-bootmenu.img"
  for _f in "${RS_KERNEL}" "${RS_INITRD}"; do
    if [ ! -f "${_f}" ]; then
      echo "ERROR: cannot find ${_f}; run remote-ssh-build.sh first"
      exit 1
    fi
  done

  BFILES=( -kernel "${RS_KERNEL}" -initrd "${RS_INITRD}" )
fi

# Attach the requested disk, or a scratch disk that contains no pool
if [ -n "${EXTRA_DISK}" ]; then
  if ! RS_DISK="$( realpath -e "${EXTRA_DISK}" )"; then
    echo "ERROR: disk image '${EXTRA_DISK}' does not exist"
    exit 1
  fi
else
  RS_DISK="${BUILD_DIR}/lab-scratch.img"
  if [ ! -f "${RS_DISK}" ]; then
    truncate -s 5G "${RS_DISK}" || exit 1
    echo "Created scratch disk ${RS_DISK}"
  fi
fi

# Only the kernel command line additions are set here; everything else comes
# from /etc/cmdline.d inside the image
KCL=( "loglevel=7" "zbm.show" )
[ -n "${TIMEOUT}" ] && KCL+=( "zbm.ssh_timeout=${TIMEOUT}" )

if ((SERIAL)); then
  KCL+=( "console=ttyS0,115200n8" )
  _lines="$( tput lines 2>/dev/null )"
  _cols="$( tput cols 2>/dev/null )"
  [ -n "${_lines}" ] && KCL+=( "zbm.lines=${_lines}" )
  [ -n "${_cols}" ] && KCL+=( "zbm.columns=${_cols}" )
  DISPLAY_ARGS=( -nographic )
  SERIAL_ARGS=( -serial mon:stdio )
else
  DISPLAY_ARGS=( -display none )
  SERIAL_ARGS=( )
fi

# Fall back to emulation when KVM is unavailable
if [ -w /dev/kvm ]; then
  ACCEL=( -cpu host -machine "type=q35,accel=kvm" )
else
  echo "WARNING: /dev/kvm is not writable; falling back to slow emulation"
  ACCEL=( -machine "type=q35" )
fi

if [ -n "${NETDEV}" ]; then
  NETDEV_ARG="${NETDEV}"
  NETDEV_ID="${NETDEV#*id=}"
  NETDEV_ID="${NETDEV_ID%%,*}"
else
  NETDEV_ARG="user,id=n0,hostfwd=tcp::${SSH_PORT}-:22"
  NETDEV_ID="n0"
fi

if ((SERIAL)); then
  echo "Serial console attached; quit qemu with Ctrl-A X"
else
  echo "Booting headless. SSH is the only way in:"
  if [ -z "${NETDEV}" ]; then
    echo "  ssh -p ${SSH_PORT} root@localhost"
    while read -r _if _addr; do
      echo "  ssh -p ${SSH_PORT} root@${_addr%%/*}   (via ${_if%:})"
    done < <( ip -4 -o addr show scope global 2>/dev/null | awk '{print $2, $4}' )
  fi
  echo "Stop the VM with: pkill -f 'qemu.*${RS_DISK##*/}'"
fi

exec qemu-system-x86_64 \
  "${BFILES[@]}" \
  -drive format=raw,file="${RS_DISK}" \
  -m "${MEMORY}" \
  -smp "${SMP}" \
  "${ACCEL[@]}" \
  -object rng-random,id=rng0,filename=/dev/urandom \
  -device virtio-rng-pci,rng=rng0 \
  -netdev "${NETDEV_ARG}" \
  -device virtio-net-pci,netdev="${NETDEV_ID}" \
  "${DISPLAY_ARGS[@]}" \
  "${SERIAL_ARGS[@]}" \
  -append "${KCL[*]}"
