#!/usr/bin/env bash
# One-shot repair on the build host after kernel ABI refresh wiped base-files.
# Fixes: missing /etc/rc.common, detached HEAD, relative-path ar mistakes.
# Does NOT bump product version (VERSION_AND_RELEASE §1.5).
set -euo pipefail

SIP_PROXY="${SIP_PROXY:-/opt/gfc/sip-proxy}"
IMT_SRC="${IMT_SRC:-/opt/gfc/immortalwrt}"
GFC_REPO="${GFC_REPO:-$SIP_PROXY/gfc-client}"
JOBS="${JOBS:-$(nproc)}"
PKGDIR="$IMT_SRC/bin/targets/x86/64/packages"
ORIG="$IMT_SRC/build_dir/target-x86_64_musl/root.orig-x86"
ROOT="$IMT_SRC/build_dir/target-x86_64_musl/root-x86"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "==> $*"; }

[[ -d "$SIP_PROXY/.git" ]] || die "not a git repo: $SIP_PROXY"
[[ -d "$IMT_SRC" ]] || die "missing IMT_SRC=$IMT_SRC"
[[ -f "$IMT_SRC/.config" ]] || die "missing $IMT_SRC/.config"
[[ -f "$IMT_SRC/package/base-files/files/etc/rc.common" ]] \
  || die "ImmortalWrt missing package/base-files/files/etc/rc.common"

# --- 1) Leave detached HEAD; sync main ---
log "checkout origin/main in $SIP_PROXY"
cd "$SIP_PROXY"
git fetch --tags origin
git checkout -B main origin/main
git reset --hard origin/main
log "sip-proxy=$(git rev-parse --short HEAD) $(git describe --tags --always 2>/dev/null || true)"
chmod +x "$GFC_REPO/deploy/immortalwrt/scripts/"*.sh

# --- 2) Rebuild base-files into target packages (absolute paths) ---
cd "$IMT_SRC"
mkdir -p "$PKGDIR"
log "compile base-files → $PKGDIR"
make package/base-files/clean V=s 2>/dev/null || true
rm -rf "$IMT_SRC/build_dir/target-x86_64_musl/linux-x86_64/base-files"
make package/base-files/compile -j"$JOBS" V=s \
  || die "package/base-files/compile failed"

BF="$(find "$PKGDIR" -maxdepth 1 -name 'base-files_*.ipk' -type f | head -1 || true)"
[[ -n "$BF" && -f "$BF" ]] || die "no base-files_*.ipk in $PKGDIR"
log "verify ipk contents: $BF"

TMP="$(mktemp -d /tmp/gfc-bfcheck.XXXXXX)"
cp -f "$BF" "$TMP/base-files.ipk"
(
  cd "$TMP"
  ar x base-files.ipk
  if [[ -f data.tar.gz ]]; then
    tar -tzf data.tar.gz
  elif [[ -f data.tar.zst ]]; then
    tar -t --zstd -f data.tar.zst
  else
    ls -la
    die "no data.tar.gz/zst in base-files.ipk"
  fi
) | grep -E 'etc/rc\.common' >/dev/null \
  || die "base-files.ipk lacks etc/rc.common"
rm -rf "$TMP"
log "base-files ipk contains etc/rc.common"

# find warnings for etc/config/network|system|dropbear|profile.d at pack time are OK.

# --- 3) Fresh package/install ---
log "bust rootfs + package/install"
rm -rf "$IMT_SRC/build_dir/target-x86_64_musl/root-"*
rm -f "$IMT_SRC/build_dir/target-x86_64_musl/stamp/.rootfs_installed"
make package/install -j1 V=s || die "package/install failed"

for root in "$ROOT" "$ORIG"; do
  [[ -f "$root/etc/rc.common" ]] || die "missing $root/etc/rc.common"
  [[ -e "$root/sbin/init" || -L "$root/sbin/init" ]] || die "missing $root/sbin/init"
  n="$(find "$root/etc/rc.d" -maxdepth 1 -name 'S*' 2>/dev/null | wc -l | tr -d ' ')"
  [[ "${n:-0}" -ge 5 ]] || die "$root has too few /etc/rc.d/S* ($n)"
  log "OK $root (rc.d/S*=$n)"
done

# --- 4) Full OEM image (kernel refresh no longer wipes base-files) ---
log "rebuild-gfc-image.sh"
export IMT_SRC GFC_REPO
bash "$GFC_REPO/deploy/immortalwrt/scripts/rebuild-gfc-image.sh"

log "DONE — safe to convert img.gz → vmdk"
ls -lt "$IMT_SRC/bin/targets/x86/64/"*ext4*combined*efi*.img.gz | head -3
grep gfc-client "$IMT_SRC/bin/targets/x86/64/"*.manifest || true
echo "ORIG rc.common: $(ls -l "$ORIG/etc/rc.common")"
exit 0
