#!/usr/bin/env bash
# One-shot recovery when package/install fails with:
#   cannot find dependency kernel (= 6.6.x~HASH-r1)
#   Packages for kmod-* found, but incompatible with the architectures configured
#
# Root cause: bin/targets/x86/64/packages missing matching kernel_*.ipk and/or
# mixed vermagic leftovers. Run on the ImmortalWrt build host, then rebuild.
set -euo pipefail

IMT_SRC="${IMT_SRC:-/opt/gfc/immortalwrt}"
GFC_REPO="${GFC_REPO:-/opt/gfc/sip-proxy/gfc-client}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"

cd "$IMT_SRC"
echo "==> IMT_SRC=$IMT_SRC"

HASH="$(find build_dir -path '*/linux-x86_64/linux-*/.vermagic' 2>/dev/null | head -1 | xargs cat | tr -d '[:space:]')"
[[ -n "$HASH" ]] || { echo "ERROR: no .vermagic — run target/linux/compile first"; exit 1; }
KVER="$(find build_dir -path '*/linux-x86_64/linux-*/.vermagic' 2>/dev/null | head -1 | xargs dirname | xargs basename | sed 's/^linux-//')"
echo "==> kernel=$KVER vermagic=$HASH"

echo "==> wipe target packages + Realtek oob ipks"
rm -rf bin/targets/x86/64/packages
mkdir -p bin/targets/x86/64/packages
find bin -type f \( \
  -name 'kmod-r8101_*.ipk' -o -name 'kmod-r8125_*.ipk' -o -name 'kmod-r8126_*.ipk' \
  -o -name 'kmod-r8168_*.ipk' -o -name 'kmod-usb-net-rtl8152-vendor_*.ipk' \
\) -delete 2>/dev/null || true

echo "==> clean rootfs stamps"
rm -rf build_dir/target-x86_64_musl/root-* 
rm -f build_dir/target-x86_64_musl/stamp/.rootfs_installed

echo "==> rebuild kernel package + all packages"
make package/kernel/linux/clean V=s 2>/dev/null || true
make target/linux/compile -j"$JOBS" V=s
make package/kernel/linux/compile -j"$JOBS" V=s
ls -la bin/targets/x86/64/packages/kernel_"${KVER}~${HASH}"*.ipk
make package/compile -j"$JOBS" V=s
make package/index -j1 V=s 2>/dev/null || true

echo "==> next: bash $GFC_REPO/deploy/immortalwrt/scripts/rebuild-gfc-image.sh"
echo "    (or: make package/install -j1 V=s && continue image build)"
