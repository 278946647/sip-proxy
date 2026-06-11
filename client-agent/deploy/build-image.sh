#!/usr/bin/env bash
# Build bootable/raw disk image from Ubuntu 22.04 base + GFC client offline package.
#
# Prerequisites (on Ubuntu 22.04 build host):
#   sudo apt install qemu-utils debootstrap arch-install-scripts
#
# Usage:
#   sudo bash build-image.sh --arch x86_64 --size 4G
#   sudo bash build-image.sh --arch aarch64 --size 4G
#
# Output: dist/client/gfc-client-{arch}-{version}.img
set -euo pipefail
_DIR="$(cd "$(dirname "$0")" && pwd)"
CLIENT_ROOT="$(cd "$_DIR/.." && pwd)"
ARCH="${ARCH:-x86_64}"
SIZE="${SIZE:-4G}"
VERSION="${VERSION:-0.1.0}"
OUT="${OUT:-$CLIENT_ROOT/dist}"
MIRROR="${MIRROR:-http://archive.ubuntu.com/ubuntu}"
SUITE="${SUITE:-jammy}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch) ARCH=${2:-}; shift 2 ;;
    --size) SIZE=${2:-}; shift 2 ;;
    --version) VERSION=${2:-}; shift 2 ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "Run as root on Ubuntu build host"
  exit 1
fi

case "$ARCH" in
  x86_64) DEB_ARCH=amd64; QEMU_ARCH=x86_64 ;;
  aarch64) DEB_ARCH=arm64; QEMU_ARCH=aarch64 ;;
  *) echo "Unsupported --arch $ARCH"; exit 1 ;;
esac

mkdir -p "$OUT"
IMG="$OUT/gfc-client-${ARCH}-${VERSION}.img"

echo "==> Build image $IMG ($SIZE)"
rm -f "$IMG"
truncate -s "$SIZE" "$IMG"
parted -s "$IMG" mklabel msdos mkpart primary ext4 1MiB 100%
LOOP=$(losetup -Pf --show "$IMG")
PART="${LOOP}p1"
sleep 1
mkfs.ext4 -F "$PART"
MNT=$(mktemp -d)
mount "$PART" "$MNT"

debootstrap --arch="$DEB_ARCH" --variant=minbase "$SUITE" "$MNT" "$MIRROR"
mount --bind /dev "$MNT/dev"
mount --bind /dev/pts "$MNT/dev/pts"
mount --bind /proc "$MNT/proc"
mount --bind /sys "$MNT/sys"

OFFLINE_TAR="$OUT/gfc-client-offline-${ARCH}-${VERSION}.tar.gz"
if [[ ! -f "$OFFLINE_TAR" ]]; then
  echo "==> Building offline tar first"
  bash "$_DIR/pack-offline.sh"
fi

cp "$OFFLINE_TAR" "$MNT/tmp/client-offline.tar.gz"

chroot "$MNT" /bin/bash <<CHROOT
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq systemd network-manager iproute2 sudo linux-image-generic
echo "gfc-client" > /etc/hostname
useradd -m -s /bin/bash gfc 2>/dev/null || true
echo "gfc:gfc" | chpasswd
echo "gfc ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/gfc
OFFLINE_DIR="/opt/gfc-client-offline-${ARCH}-${VERSION}"
mkdir -p /opt && tar xzf /tmp/client-offline.tar.gz -C /opt
ln -sf "\${OFFLINE_DIR}/install.sh" /root/install-gfc-client.sh
cat >/etc/systemd/system/gfc-first-boot.service <<UNIT
[Unit]
Description=GFC first boot helper
ConditionPathExists=!/var/lib/gfc-client/.installed

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'OFF=\$(ls -d /opt/gfc-client-offline-* 2>/dev/null | head -1); if [ -f /etc/gfc-client/activation.b32 ] && [ -n "\$OFF" ]; then "\$OFF/install.sh" --yes; mkdir -p /var/lib/gfc-client; touch /var/lib/gfc-client/.installed; fi'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
systemctl enable gfc-first-boot.service
CHROOT

umount "$MNT/dev/pts" "$MNT/dev" "$MNT/proc" "$MNT/sys" 2>/dev/null || true
umount "$MNT"
losetup -d "$LOOP"
rmdir "$MNT"

echo "==> Image ready: $IMG"
echo "    Flash: sudo dd if=$IMG of=/dev/sdX bs=4M status=progress"
echo "    Before first boot: mount partition and flash line code to /etc/gfc-client/activation.b32"
