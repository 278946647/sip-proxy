#!/usr/bin/env bash
# One-shot recovery when package/install fails with:
#   cannot find dependency kernel (= 6.6.x~HASH-r1)
#   Packages for kmod-* found, but incompatible with the architectures configured
#
# Also use when package/compile Error 2 appears after a successful gfc-client ipk
# (parallel make often hides the *real* failing package — see NOTES below).
#
# patchelf: "cannot find section '.dynamic'" on gfc-api/gfc-agent is NORMAL —
# those Go binaries are statically linked; it is not the compile failure.
set -euo pipefail

IMT_SRC="${IMT_SRC:-/opt/gfc/immortalwrt}"
GFC_REPO="${GFC_REPO:-/opt/gfc/sip-proxy/gfc-client}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
# Set JOBS=1 to surface the first real package failure clearly.
SERIAL="${GFC_SERIAL_COMPILE:-0}"

# Must exist under bin/ after package/compile (name prefix of *.ipk).
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
  local name=$1
  find bin -type f -name "${name}_*.ipk" 2>/dev/null | grep -q .
}

verify_required_ipks() {
  local missing=0 name
  log "verify required ipks under bin/"
  for name in "${REQUIRED_IPKS[@]}"; do
    if have_ipk "$name"; then
      echo "    OK  $name"
    else
      echo "    MISSING  $name_*.ipk"
      missing=1
    fi
  done
  [[ "$missing" -eq 0 ]] || die "required ipks missing — fix .config / feeds, then re-run"
}

cd "$IMT_SRC"
log "IMT_SRC=$IMT_SRC"

HASH="$(find build_dir -path '*/linux-x86_64/linux-*/.vermagic' 2>/dev/null | head -1 | xargs cat | tr -d '[:space:]')"
[[ -n "$HASH" ]] || die "no .vermagic — run: make target/linux/compile"
KVER="$(find build_dir -path '*/linux-x86_64/linux-*/.vermagic' 2>/dev/null | head -1 | xargs dirname | xargs basename | sed 's/^linux-//')"
log "kernel=$KVER vermagic=$HASH"

log "wipe target packages + Realtek oob ipks"
rm -rf bin/targets/x86/64/packages
mkdir -p bin/targets/x86/64/packages
find bin -type f \( \
  -name 'kmod-r8101_*.ipk' -o -name 'kmod-r8125_*.ipk' -o -name 'kmod-r8126_*.ipk' \
  -o -name 'kmod-r8168_*.ipk' -o -name 'kmod-usb-net-rtl8152-vendor_*.ipk' \
\) -delete 2>/dev/null || true

log "clean rootfs stamps"
rm -rf build_dir/target-x86_64_musl/root-*
rm -f build_dir/target-x86_64_musl/stamp/.rootfs_installed

COMP_JOBS="$JOBS"
[[ "$SERIAL" == "1" ]] && COMP_JOBS=1

log "rebuild kernel package (kernel_*.ipk + kmods) jobs=$COMP_JOBS"
make package/kernel/linux/clean V=s 2>/dev/null || true
make target/linux/compile -j"$COMP_JOBS" V=s
make package/kernel/linux/compile -j"$COMP_JOBS" V=s
ls -la bin/targets/x86/64/packages/kernel_"${KVER}~${HASH}"*.ipk \
  || die "kernel ipk not produced in bin/targets/x86/64/packages/"

log "compile ALL selected packages (tc / sing-box / unbound / curl / …)"
if ! make package/compile -j"$COMP_JOBS" V=s; then
  echo ""
  echo "ERROR: package/compile failed."
  echo "NOTE: patchelf '.dynamic' on gfc-* is usually harmless (static Go)."
  echo "NOTE: with -j$COMP_JOBS the failing package may be earlier in the log."
  echo "Re-run serial to see the first real error:"
  echo "  GFC_SERIAL_COMPILE=1 JOBS=1 $0"
  echo "  # or:"
  echo "  cd $IMT_SRC && make package/compile -j1 V=s 2>&1 | tee /tmp/gfc-pkg.log"
  echo "  grep -nE 'Error [0-9]|make\\[[0-9]\\]: \\*\\*\\*' /tmp/gfc-pkg.log | tail -40"
  exit 1
fi
make package/index -j1 V=s 2>/dev/null || true

verify_required_ipks

log "OK — kernel + required GFC packages present"
echo "==> next: bash $GFC_REPO/deploy/immortalwrt/scripts/rebuild-gfc-image.sh"
