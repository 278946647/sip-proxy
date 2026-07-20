#!/usr/bin/env bash
# Recover package/install when opkg cannot find:
#   kernel (= 6.6.x~HASH-r1)
#
# IMPORTANT: only refresh bin/targets/x86/64/packages (kernel + kmods).
# Do NOT run full `make package/compile` by default — that rebuilds the entire
# world and often fails on an unrelated package under -jN (Error 2), while
# gfc-client / grub / etc. look fine at the end of the log.
#
# Userspace ipks live under bin/packages/x86_64/ and are kept.
# Set GFC_FULL_PACKAGE_COMPILE=1 only if you intentionally want a full rebuild.
#
# patchelf '.dynamic' on static gfc-* binaries is harmless.
set -euo pipefail

IMT_SRC="${IMT_SRC:-/opt/gfc/immortalwrt}"
GFC_REPO="${GFC_REPO:-/opt/gfc/sip-proxy/gfc-client}"
GFC_DEPLOY="${GFC_REPO}/deploy/immortalwrt"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
FULL="${GFC_FULL_PACKAGE_COMPILE:-0}"

# GFC OEM mandatory packages (gfc-package-index.txt + kernel for install).
REQUIRED_IPKS=(
  kernel
  gfc-client
  luci-app-gfc
  luci-base
  luci-theme-bootstrap
  luci-mod-admin-full
  sing-box
  unbound-daemon
  unbound-checkconf
  dnsmasq-full
  tc-tiny
  kmod-sched-core
  kmod-sched
  kmod-ifb
  kmod-tcp-bbr
  kmod-tun
  kmod-nft-core
  nftables-json
  curl
  wget-ssl
  tcpdump
  iftop
  bmon
  autossh
  libcap-bin
  ca-bundle
  ip-full
  resize2fs
  parted
  partx-utils
  losetup
)

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "==> $*"; }

have_ipk() {
  find bin -type f -name "${1}_*.ipk" 2>/dev/null | grep -q .
}

list_missing() {
  local name
  for name in "${REQUIRED_IPKS[@]}"; do
    have_ipk "$name" || echo "$name"
  done
}

verify_required_ipks() {
  local missing=0 name
  log "verify required ipks under bin/"
  for name in "${REQUIRED_IPKS[@]}"; do
    if have_ipk "$name"; then
      echo "    OK  $name  $(find bin -name "${name}_*.ipk" | head -1 | xargs -r basename)"
    else
      echo "    MISSING  ${name}_*.ipk"
      missing=1
    fi
  done
  [[ "$missing" -eq 0 ]] || return 1
  return 0
}

# Compile only GFC-critical packages that are missing (not full world).
compile_missing_gfc_packages() {
  local miss
  miss="$(list_missing | tr '\n' ' ')"
  [[ -n "${miss// /}" ]] || return 0
  log "missing ipks — selective compile: $miss"

  # gfc feed
  if ! have_ipk gfc-client || ! have_ipk luci-app-gfc; then
    make package/feeds/gfc/gfc-client/compile -j1 V=s "GFC_CLIENT_SRC=$GFC_REPO" \
      || die "gfc-client compile failed"
    make package/feeds/gfc/luci-app-gfc/compile -j1 V=s \
      || die "luci-app-gfc compile failed"
  fi
  # tc / expand / common (same targets as rebuild-gfc-image.sh build_packages)
  if ! have_ipk tc-tiny; then
    make package/network/utils/iproute2/compile -j"$JOBS" V=s \
      || die "iproute2/tc-tiny compile failed"
  fi
  if ! have_ipk resize2fs; then
    make package/utils/e2fsprogs/compile -j"$JOBS" V=s || die "e2fsprogs/resize2fs failed"
  fi
  if ! have_ipk partx-utils || ! have_ipk losetup; then
    make package/utils/util-linux/compile -j"$JOBS" V=s || die "util-linux failed"
  fi
  if ! have_ipk parted; then
    local parted_tgt=package/feeds/packages/parted
    [[ -d package/feeds/packages/utils/parted ]] && parted_tgt=package/feeds/packages/utils/parted
    make "${parted_tgt}/compile" -j"$JOBS" V=s || die "parted compile failed"
  fi
  # Remaining feed/base packages: one package/compile pass only if still missing
  # and user opted in — otherwise print what is still missing.
  if list_missing | grep -q .; then
    if [[ "$FULL" == "1" ]]; then
      log "GFC_FULL_PACKAGE_COMPILE=1 — make package/compile (slow; may fail on unrelated pkgs)"
      BUILD_LOG=1 make package/compile -j"$JOBS" V=s \
        || die "full package/compile failed — see logs/package/*/compile.txt"
    else
      log "WARN: still missing after selective compile:"
      list_missing | sed 's/^/    /'
      echo "Fix .config / feeds, or re-run with: GFC_FULL_PACKAGE_COMPILE=1 $0"
      echo "To find a parallel-world failure: make package/compile -j1 V=s 2>&1 | tee /tmp/gfc-pkg.log"
      return 1
    fi
  fi
}

cd "$IMT_SRC"
log "IMT_SRC=$IMT_SRC"

# Merge GFC package selection so missing packages can be built.
if [[ -x "$GFC_DEPLOY/scripts/rebuild-gfc-image.sh" ]]; then
  log "hint: ensure .config has GFC packages (rebuild-gfc-image merges gfc-packages.config)"
fi

HASH="$(find build_dir -path '*/linux-x86_64/linux-*/.vermagic' 2>/dev/null | head -1 | xargs cat | tr -d '[:space:]')"
[[ -n "$HASH" ]] || die "no .vermagic — run: make target/linux/compile"
KVER="$(find build_dir -path '*/linux-x86_64/linux-*/.vermagic' 2>/dev/null | head -1 | xargs dirname | xargs basename | sed 's/^linux-//')"
log "kernel=$KVER vermagic=$HASH"

log "wipe ONLY bin/targets/x86/64/packages (kernel+kmods); keep bin/packages/x86_64/*"
rm -rf bin/targets/x86/64/packages
mkdir -p bin/targets/x86/64/packages
find bin -type f \( \
  -name 'kmod-r8101_*.ipk' -o -name 'kmod-r8125_*.ipk' -o -name 'kmod-r8126_*.ipk' \
  -o -name 'kmod-r8168_*.ipk' -o -name 'kmod-usb-net-rtl8152-vendor_*.ipk' \
\) -delete 2>/dev/null || true

log "clean rootfs stamps (force package/install to re-run)"
rm -rf build_dir/target-x86_64_musl/root-*
rm -f build_dir/target-x86_64_musl/stamp/.rootfs_installed

log "rebuild kernel + kmods only"
make package/kernel/linux/clean V=s 2>/dev/null || true
make target/linux/compile -j"$JOBS" V=s || die "target/linux/compile failed"
make package/kernel/linux/compile -j"$JOBS" V=s || die "package/kernel/linux/compile failed"
ls -la bin/targets/x86/64/packages/kernel_"${KVER}~${HASH}"*.ipk \
  || die "kernel ipk not in bin/targets/x86/64/packages/"

if [[ "$FULL" == "1" ]]; then
  log "GFC_FULL_PACKAGE_COMPILE=1 — full package/compile"
  BUILD_LOG=1 make package/compile -j"$JOBS" V=s \
    || die "full package/compile failed"
fi

compile_missing_gfc_packages || true
make package/index -j1 V=s 2>/dev/null || true

verify_required_ipks || die "required GFC ipks still missing"

log "OK — kernel + required GFC packages present"
echo ""
echo "Next:"
echo "  bash $GFC_DEPLOY/scripts/rebuild-gfc-image.sh"
echo "Or install only:"
echo "  cd $IMT_SRC && make package/install -j1 V=s"
