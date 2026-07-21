#!/usr/bin/env bash
# One-shot repair: base-files + rootfs + OEM image.
# Does NOT bump product version.
set -euo pipefail

SIP_PROXY="${SIP_PROXY:-/opt/gfc/sip-proxy}"
IMT_SRC="${IMT_SRC:-/opt/gfc/immortalwrt}"
GFC_REPO="${GFC_REPO:-$SIP_PROXY/gfc-client}"
JOBS="${JOBS:-$(nproc)}"
PKGDIR="$IMT_SRC/bin/targets/x86/64/packages"
ORIG="$IMT_SRC/build_dir/target-x86_64_musl/root.orig-x86"
ROOT="$IMT_SRC/build_dir/target-x86_64_musl/root-x86"
LIB="$GFC_REPO/deploy/immortalwrt/scripts/gfc-base-files-lib.sh"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "==> $*"; }

[[ -f "$LIB" ]] || die "missing $LIB — git pull / checkout main first"
# shellcheck disable=SC1090
source "$LIB"

[[ -d "$SIP_PROXY/.git" ]] || die "not a git repo: $SIP_PROXY"
[[ -d "$IMT_SRC" ]] || die "missing IMT_SRC=$IMT_SRC"
[[ -f "$IMT_SRC/.config" ]] || die "missing $IMT_SRC/.config"
[[ -f "$IMT_SRC/package/base-files/files/etc/rc.common" ]] \
  || die "ImmortalWrt missing package/base-files/files/etc/rc.common"

log "checkout origin/main in $SIP_PROXY"
cd "$SIP_PROXY"
git fetch --tags origin
git checkout -B main origin/main
git reset --hard origin/main
log "sip-proxy=$(git rev-parse --short HEAD)"
chmod +x "$GFC_REPO/deploy/immortalwrt/scripts/"*.sh
# re-source after hard reset in case lib updated
source "$GFC_REPO/deploy/immortalwrt/scripts/gfc-base-files-lib.sh"

cd "$IMT_SRC"
mkdir -p "$PKGDIR"

log "compile base-files (find: missing network/system/dropbear warnings are NORMAL)"
make package/base-files/clean V=s 2>/dev/null || true
rm -rf "$IMT_SRC/build_dir/target-x86_64_musl/linux-x86_64/base-files"
make package/base-files/compile -j"$JOBS" V=s \
  || die "package/base-files/compile failed"

gfc_assert_base_files_built || die "base-files assert failed"

STAGE="$(gfc_base_files_staging_rc "$IMT_SRC")"
log "staging: $(ls -l "$STAGE")"

log "bust rootfs + package/install"
rm -rf "$IMT_SRC/build_dir/target-x86_64_musl/root-"*
rm -f "$IMT_SRC/build_dir/target-x86_64_musl/stamp/.rootfs_installed"
make package/install -j1 V=s || die "package/install failed"

for root in "$ROOT" "$ORIG"; do
  [[ -f "$root/etc/rc.common" ]] || die "missing $root/etc/rc.common — base-files not installed into rootfs"
  [[ -e "$root/sbin/init" || -L "$root/sbin/init" ]] || die "missing $root/sbin/init"
done
# TARGET_DIR has Enabling; ORIG is pre-enable — sync rc.d before requiring S* on ORIG
n_root="$(find "$ROOT/etc/rc.d" -maxdepth 1 -name 'S*' 2>/dev/null | wc -l | tr -d ' ')"
[[ "${n_root:-0}" -ge 5 ]] || die "$ROOT has too few /etc/rc.d/S* ($n_root)"
log "OK $ROOT (rc.d/S*=$n_root)"
rm -rf "$ORIG/etc/rc.d"
cp -a "$ROOT/etc/rc.d" "$ORIG/etc/rc.d"
[[ -f "$ROOT/etc/inittab" ]] && cp -a "$ROOT/etc/inittab" "$ORIG/etc/inittab"
n_orig="$(find "$ORIG/etc/rc.d" -maxdepth 1 -name 'S*' 2>/dev/null | wc -l | tr -d ' ')"
[[ "${n_orig:-0}" -ge 5 ]] || die "$ORIG still too few S* after sync ($n_orig)"
log "OK $ORIG (rc.d/S*=$n_orig, synced from TARGET_DIR)"

log "rebuild-gfc-image.sh"
export IMT_SRC GFC_REPO
bash "$GFC_REPO/deploy/immortalwrt/scripts/rebuild-gfc-image.sh"

log "DONE"
ls -lt "$IMT_SRC/bin/targets/x86/64/"*ext4*combined*efi*.img.gz | head -3
grep gfc-client "$IMT_SRC/bin/targets/x86/64/"*.manifest || true
ls -l "$ORIG/etc/rc.common"
exit 0
