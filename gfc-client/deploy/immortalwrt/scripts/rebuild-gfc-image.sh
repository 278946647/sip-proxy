#!/usr/bin/env bash
# Build ImmortalWrt image with gfc-client + luci-app-gfc in rootfs/manifest.
set -euo pipefail

IMT_SRC="${IMT_SRC:-/opt/gfc/immortalwrt}"
GFC_REPO="${GFC_REPO:-/opt/gfc/sip-proxy/gfc-client}"
JOBS="${JOBS:-$(nproc)}"
export PATH="/usr/local/go/bin:${PATH:-}"
export GOFLAGS="${GOFLAGS:--buildvcs=false}"

die() { echo "ERROR: $*" >&2; exit 1; }

require() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1 (install Go 1.22+ to /usr/local/go)"
}

merge_gfc_config() {
  local fragment="$GFC_REPO/deploy/immortalwrt/config/gfc-packages.config"
  [[ -f "$IMT_SRC/.config" ]] || die "missing $IMT_SRC/.config (run target make defconfig first)"
  [[ -f "$fragment" ]] || die "missing $fragment"
  cd "$IMT_SRC"
  make -j1 V=s prepare >/dev/null 2>&1 || true
  local tmp
  tmp="$(mktemp)"
  grep -vE 'CONFIG_PACKAGE_gfc-client|CONFIG_PACKAGE_luci-app-gfc' .config >"$tmp" || true
  cat "$tmp" "$fragment" >.config
  rm -f "$tmp"
  grep -q '^CONFIG_PACKAGE_gfc-client=y$' .config || echo 'CONFIG_PACKAGE_gfc-client=y' >>.config
  grep -q '^CONFIG_PACKAGE_luci-app-gfc=y$' .config || echo 'CONFIG_PACKAGE_luci-app-gfc=y' >>.config
  # Do NOT run oldconfig/syncconfig here — full make will sync; we verify after.
}

verify_kconfig_symbol() {
  cd "$IMT_SRC"
  if ! grep -q '^Package: gfc-client$' tmp/.packageinfo 2>/dev/null; then
    die "gfc-client not in tmp/.packageinfo — run setup-immortalwrt-feed.sh all"
  fi
  if ! ./scripts/package-metadata.pl kconfig tmp/.packageinfo .config 6.6 2>/dev/null | grep -q 'config PACKAGE_gfc-client'; then
    echo "WARN: PACKAGE_gfc-client not in generated Kconfig — syncconfig may drop .config lines" >&2
    echo "      Run: bash $GFC_REPO/deploy/immortalwrt/scripts/setup-immortalwrt-feed.sh all" >&2
  fi
}

verify_dotconfig() {
  cd "$IMT_SRC"
  grep -q '^CONFIG_PACKAGE_gfc-client=y$' .config || die ".config missing CONFIG_PACKAGE_gfc-client=y"
  grep -q '^CONFIG_PACKAGE_luci-app-gfc=y$' .config || die ".config missing CONFIG_PACKAGE_luci-app-gfc=y"
}

prepare_gfc_env() {
  local env_dir="$GFC_REPO/deploy/immortalwrt/package/files/etc/gfc-client"
  if [[ ! -f "$env_dir/gfc.env" ]]; then
    cp "$env_dir/gfc.env.example" "$env_dir/gfc.env"
  fi
  cd "$GFC_REPO"
  go mod tidy
}

build_packages() {
  cd "$IMT_SRC"
  make "package/gfc-client/clean" V=s 2>/dev/null || true
  make "package/gfc-client/compile" V=s "GFC_CLIENT_SRC=$GFC_REPO"
  make "package/luci-app-gfc/compile" V=s
  find bin -name 'gfc-client*.ipk' -print | grep -q . || die "gfc-client ipk not produced"
}

force_rootfs() {
  cd "$IMT_SRC"
  verify_dotconfig
  rm -rf build_dir/target-x86_64_musl/root-*
  rm -f build_dir/target-x86_64_musl/stamp/.rootfs_installed
  rm -f build_dir/target-x86_64_musl/stamp/.target_install
  rm -f staging_dir/target-x86_64_musl/stamp/.rootfs_installed 2>/dev/null || true
}

build_image() {
  cd "$IMT_SRC"
  # syncconfig runs inside make; re-assert GFC lines if stripped mid-build
  merge_gfc_config
  make -j"$JOBS" V=s
  if ! grep -q '^CONFIG_PACKAGE_gfc-client=y$' .config; then
    echo "WARN: syncconfig removed GFC from .config — re-merging and rebuilding rootfs" >&2
    merge_gfc_config
    force_rootfs
    make "package/gfc-client/install" V=s "GFC_CLIENT_SRC=$GFC_REPO"
    make "package/luci-app-gfc/install" V=s
    make target/install -j"$JOBS" V=s
  fi
}

verify_manifest() {
  cd "$IMT_SRC"
  local manifest="bin/targets/x86/64/immortalwrt-x86-64-generic.manifest"
  [[ -f "$manifest" ]] || die "missing $manifest"
  grep -i gfc-client "$manifest" >/dev/null || die "manifest has no gfc-client — GFC not in firmware"
  grep -i luci-app-gfc "$manifest" >/dev/null || die "manifest has no luci-app-gfc"
  echo "==> OK: manifest includes GFC packages"
  grep -i gfc "$manifest"
  ls -lh bin/targets/x86/64/*ext4*combined*efi*.img.gz
}

main() {
  require go
  bash "$GFC_REPO/deploy/immortalwrt/scripts/setup-immortalwrt-feed.sh" all
  merge_gfc_config
  verify_kconfig_symbol
  verify_dotconfig
  prepare_gfc_env
  build_packages
  force_rootfs
  build_image
  verify_manifest
}

main "$@"
