#!/usr/bin/env bash
# Build ImmortalWrt image with gfc-client + luci-app-gfc in rootfs/manifest.
set -euo pipefail

IMT_SRC="${IMT_SRC:-/opt/gfc/immortalwrt}"
GFC_REPO="${GFC_REPO:-/opt/gfc/sip-proxy/gfc-client}"
JOBS="${JOBS:-$(nproc)}"
export PATH="/usr/local/go/bin:${PATH:-}"
export GOFLAGS="${GOFLAGS:--buildvcs=false}"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "==> $*"; }

require() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1 (install Go 1.22+ to /usr/local/go)"
}

merge_gfc_config() {
  local fragment="$GFC_REPO/deploy/immortalwrt/config/gfc-packages.config"
  [[ -f "$IMT_SRC/.config" ]] || die "missing $IMT_SRC/.config"
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
}

ensure_feeds_only() {
  cd "$IMT_SRC"
  if [[ -d package/feeds/gfc/gfc-client ]]; then
    log "feed path OK: package/feeds/gfc/gfc-client"
    # Legacy manual symlink tree confuses metadata; remove if feed exists.
    if [[ -L package/gfc/gfc-client || -d package/gfc/gfc-client ]]; then
      log "remove legacy package/gfc (use package/feeds/gfc only)"
      rm -rf package/gfc
    fi
  else
    die "package/feeds/gfc/gfc-client missing — run setup-immortalwrt-feed.sh all"
  fi
  grep 'Source-Makefile: package/feeds/gfc/gfc-client/Makefile' tmp/.packageinfo >/dev/null \
    || die "packageinfo still not on feeds path — re-run setup-immortalwrt-feed.sh all"
}

verify_dotconfig() {
  cd "$IMT_SRC"
  grep -q '^CONFIG_PACKAGE_gfc-client=y$' .config || die ".config missing CONFIG_PACKAGE_gfc-client=y"
  grep -q '^CONFIG_PACKAGE_luci-app-gfc=y$' .config || die ".config missing CONFIG_PACKAGE_luci-app-gfc=y"
}

prepare_gfc_env() {
  local env_dir="$GFC_REPO/deploy/immortalwrt/package/files/etc/gfc-client"
  [[ -f "$env_dir/gfc.env" ]] || cp "$env_dir/gfc.env.example" "$env_dir/gfc.env"
  cd "$GFC_REPO"
  go mod tidy
}

build_packages() {
  cd "$IMT_SRC"
  make "package/gfc-client/clean" V=s 2>/dev/null || true
  make "package/feeds/gfc/gfc-client/compile" V=s "GFC_CLIENT_SRC=$GFC_REPO" \
    || make "package/gfc-client/compile" V=s "GFC_CLIENT_SRC=$GFC_REPO"
  make "package/feeds/gfc/luci-app-gfc/compile" V=s \
    || make "package/luci-app-gfc/compile" V=s
  find bin -name 'gfc-client*.ipk' -print | grep -q . || die "gfc-client ipk not produced"
}

find_rootfs_dir() {
  find "$IMT_SRC/build_dir/target-x86_64_musl" -maxdepth 1 -type d -name 'root-*' 2>/dev/null | head -1
}

force_rootfs() {
  cd "$IMT_SRC"
  rm -rf build_dir/target-x86_64_musl/root-*
  rm -f build_dir/target-x86_64_musl/stamp/.rootfs_installed
  rm -f build_dir/target-x86_64_musl/stamp/.target_install
}

opkg_install_gfc_into_rootfs() {
  local root="$1"
  local opkg="$IMT_SRC/staging_dir/host/bin/opkg"
  local ipk lipk
  ipk="$(find "$IMT_SRC/bin" -name 'gfc-client_*.ipk' | head -1)"
  lipk="$(find "$IMT_SRC/bin" -name 'luci-app-gfc_*.ipk' | head -1)"
  [[ -n "$ipk" ]] || die "gfc-client ipk not found under bin/"
  [[ -x "$opkg" ]] || die "host opkg missing: $opkg"
  [[ -d "$root" ]] || die "rootfs dir missing: $root"
  log "opkg install gfc into $root"
  "$opkg" install --dest "$root" --force-depends --force-overwrite "$ipk"
  if [[ -n "$lipk" ]]; then
    "$opkg" install --dest "$root" --force-depends --force-overwrite "$lipk"
  fi
  [[ -x "$root/usr/bin/gfc-api" ]] || die "opkg install did not place /usr/bin/gfc-api"
}

build_image() {
  cd "$IMT_SRC"
  merge_gfc_config
  verify_dotconfig

  log "target/install (sequential rootfs)"
  make target/install -j1 V=s

  local root
  root="$(find_rootfs_dir)"
  if [[ -z "$root" ]] || [[ ! -x "$root/usr/bin/gfc-api" ]]; then
    log "gfc missing from rootfs after target/install — opkg inject fallback"
    [[ -n "$root" ]] || die "no root-* directory; target/install failed"
    opkg_install_gfc_into_rootfs "$root"
    log "rebuild images from patched rootfs"
    make target/install -j1 V=s
  fi
}

verify_manifest() {
  cd "$IMT_SRC"
  local manifest="bin/targets/x86/64/immortalwrt-x86-64-generic.manifest"
  local root
  root="$(find_rootfs_dir)"
  [[ -f "$manifest" ]] || die "missing $manifest"
  log "rootfs: $(test -x "$root/usr/bin/gfc-api" && echo has gfc-api || echo NO gfc-api)"
  log "manifest gfc lines:"
  grep -i gfc "$manifest" || true
  grep -i gfc-client "$manifest" >/dev/null || die "manifest has no gfc-client"
  grep -i luci-app-gfc "$manifest" >/dev/null || die "manifest has no luci-app-gfc"
  ls -lh bin/targets/x86/64/*ext4*combined*efi*.img.gz
}

main() {
  require go
  bash "$GFC_REPO/deploy/immortalwrt/scripts/setup-immortalwrt-feed.sh" all
  ensure_feeds_only
  merge_gfc_config
  verify_dotconfig
  prepare_gfc_env
  build_packages
  force_rootfs
  build_image
  verify_manifest
  log "GFC firmware build OK"
}

main "$@"
