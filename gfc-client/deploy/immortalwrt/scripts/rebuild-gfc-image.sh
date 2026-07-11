#!/usr/bin/env bash
# Build ImmortalWrt image with gfc-client + luci-app-gfc in rootfs/manifest.
set -euo pipefail

IMT_SRC="${IMT_SRC:-/opt/gfc/immortalwrt}"
GFC_REPO="${GFC_REPO:-/opt/gfc/sip-proxy/gfc-client}"
GFC_DEPLOY="${GFC_REPO}/deploy/immortalwrt"
GFC_FEED_SETUP="${GFC_DEPLOY}/scripts/setup-immortalwrt-feed.sh"
TARGET_BUILD="${IMT_SRC}/build_dir/target-x86_64_musl"
LINUX_BUILD="${TARGET_BUILD}/linux-x86_64"
ROOTFS_DIR="${ROOTFS_DIR:-${TARGET_BUILD}/root-x86}"
STAGING_PKGINFO="${IMT_SRC}/staging_dir/target-x86_64_musl/pkginfo"
JOBS="${JOBS:-$(nproc)}"
export PATH="/usr/local/go/bin:${PATH:-}"
export GOFLAGS="${GOFLAGS:--buildvcs=false}"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "==> $*"; }

require() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1 (install Go 1.22+ to /usr/local/go)"
}

require_feed_setup_script() {
  [[ -f "$GFC_FEED_SETUP" ]] || die "missing $GFC_FEED_SETUP"
  grep -q 'GFC_FEED_SETUP_VERSION=3' "$GFC_FEED_SETUP" \
    || die "outdated setup script (need v3: feeds update -i + install -f). Run: cd /opt/gfc/sip-proxy && git pull"
  grep -q 'feeds update -i gfc' "$GFC_FEED_SETUP" \
    || die "setup script missing feeds update -i — git pull sip-proxy on build machine"
}

load_feed_setup() {
  require_feed_setup_script
  # shellcheck disable=SC1090
  source "$GFC_FEED_SETUP"
}

merge_gfc_config() {
  local fragment="$GFC_DEPLOY/config/gfc-packages.config"
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

# OpenWrt image install list comes from Kconfig package-y + pkginfo/*.install (not per-feed make install).
refresh_build_metadata() {
  cd "$IMT_SRC"
  log "refresh package metadata (prepare)"
  make -j1 V=s prepare
  grep -qi 'gfc-client' tmp/.packageinfo \
    || die "gfc-client missing from tmp/.packageinfo — feeds/Kconfig not registered"
  if ! grep -Eiq 'gfc-client|feeds/gfc/gfc-client' tmp/.packagedeps 2>/dev/null; then
    log "WARN: gfc-client not obvious in tmp/.packagedeps (may still install via opkg fallback)"
  fi
  if [[ -f tmp/.config-package.in ]] && ! grep -q 'CONFIG_PACKAGE_gfc-client' tmp/.config-package.in; then
    die "CONFIG_PACKAGE_gfc-client missing from Kconfig (tmp/.config-package.in) — check DEPENDS/feeds path"
  fi
}

ensure_feeds_only() {
  cd "$IMT_SRC"
  [[ -d package/feeds/gfc/gfc-client ]] \
    || die "package/feeds/gfc/gfc-client missing after register_feed"
  [[ ! -e package/gfc-client && ! -e package/luci-app-gfc && ! -e package/gfc ]] \
    || die "legacy package/gfc* still present — re-run register_feed"
  grep 'Source-Makefile: package/feeds/gfc/gfc-client/Makefile' tmp/.packageinfo >/dev/null \
    || die "packageinfo still not on feeds path — re-run register_feed"
  log "feed path OK: package/feeds/gfc/gfc-client"
}

verify_dotconfig() {
  cd "$IMT_SRC"
  grep -q '^CONFIG_PACKAGE_gfc-client=y$' .config || die ".config missing CONFIG_PACKAGE_gfc-client=y"
  grep -q '^CONFIG_PACKAGE_luci-app-gfc=y$' .config || die ".config missing CONFIG_PACKAGE_luci-app-gfc=y"
}

prepare_gfc_env() {
  local env_dir="$GFC_DEPLOY/package/files/etc/gfc-client"
  [[ -f "$env_dir/gfc.env" ]] || cp "$env_dir/gfc.env.example" "$env_dir/gfc.env"
  cd "$GFC_REPO"
  go mod tidy
}

make_gfc_package() {
  local target="$1"
  shift
  cd "$IMT_SRC"
  make "$target/compile" -j1 V=s "$@"
}

build_packages() {
  cd "$IMT_SRC"
  make "package/feeds/gfc/gfc-client/clean" V=s 2>/dev/null || true
  log "compile gfc-client ipk"
  make_gfc_package "package/feeds/gfc/gfc-client" "GFC_CLIENT_SRC=$GFC_REPO"
  log "compile luci-app-gfc ipk"
  make_gfc_package "package/feeds/gfc/luci-app-gfc"
  find bin -name 'gfc-client*.ipk' -print | grep -q . || die "gfc-client ipk not produced"
  local pkginfo="$STAGING_PKGINFO/gfc-client.default.install"
  if [[ -f "$pkginfo" ]]; then
    log "pkginfo: $(cat "$pkginfo")"
  else
    log "WARN: $pkginfo missing (package/install may skip gfc; will use rootfs inject)"
  fi
}

find_rootfs_dir() {
  if [[ -d "$ROOTFS_DIR" ]]; then
    printf '%s\n' "$ROOTFS_DIR"
    return 0
  fi
  find "$TARGET_BUILD" -maxdepth 1 -type d -name 'root-*' 2>/dev/null | head -1
}

find_gfc_ipk() {
  find "$IMT_SRC/bin" -name 'gfc-client_*.ipk' | head -1
}

find_luci_ipk() {
  find "$IMT_SRC/bin" -name 'luci-app-gfc_*.ipk' | head -1
}

# Bust rootfs + image outputs. Do NOT call make target/install alone after this —
# OpenWrt may skip package/install when stamps exist, then tar/mksquashfs fails on missing root-x86.
force_rootfs() {
  cd "$IMT_SRC"
  log "bust rootfs + image cache (keep package build_dir/ipk)"
  rm -rf "$TARGET_BUILD"/root-*
  rm -rf "$LINUX_BUILD"/root.squashfs "$LINUX_BUILD"/root.ext4 "$LINUX_BUILD"/tmp
  rm -f "$TARGET_BUILD/stamp/.rootfs_installed"
  rm -f "$TARGET_BUILD/stamp/.target_install"
  rm -f "$IMT_SRC/bin/targets/x86/64/"*.manifest
  rm -f "$IMT_SRC/bin/targets/x86/64/"*rootfs.tar.gz
  rm -f "$IMT_SRC/bin/targets/x86/64/"*ext4*combined*efi*.img.gz
}

require_rootfs_populated() {
  local root="$1"
  [[ -d "$root" ]] || die "rootfs dir missing: $root (run make package/install first)"
  [[ -d "$root/etc" && -d "$root/usr" ]] \
    || die "rootfs dir incomplete: $root (package/install did not populate rootfs)"
}

install_rootfs() {
  cd "$IMT_SRC"
  log "package/install -> populate $ROOTFS_DIR"
  make package/install -j1 V=s
  require_rootfs_populated "$ROOTFS_DIR"
}

diagnose_missing_gfc() {
  local root="$1"
  log "diagnose: gfc not in $root after package/install"
  grep -E 'CONFIG_PACKAGE_gfc|gfc-client' "$IMT_SRC/.config" || true
  ls -la "$STAGING_PKGINFO"/gfc-client* 2>/dev/null || log "no gfc-client pkginfo files"
  if [[ -f "$IMT_SRC/tmp/opkg_install_list" ]]; then
    log "opkg_install_list gfc lines:"
    grep -i gfc "$IMT_SRC/tmp/opkg_install_list" || log "(gfc not in opkg_install_list)"
  fi
}

opkg_install_ipk_into_rootfs() {
  local root="$1" ipk="$2"
  local opkg="$IMT_SRC/staging_dir/host/bin/opkg"
  local arch="${GFC_OPKG_ARCH:-x86}"
  [[ -x "$opkg" ]] || die "host opkg missing: $opkg"
  mkdir -p "$root/tmp"
  IPKG_NO_SCRIPT=1 IPKG_INSTROOT="$root" TMPDIR="$root/tmp" \
    "$opkg" --offline-root "$root" \
      --force-postinstall --force-overwrite --force-depends \
      --add-dest root:/ \
      --add-arch "all:100" \
      --add-arch "${arch}:200" \
      install "$ipk"
}

ipkg_extract_into_rootfs() {
  local ipk="$1" root="$2"
  local tmp
  require ar
  tmp="$(mktemp -d)"
  (
    cd "$tmp"
    ar x "$ipk"
    tar xzf data.tar.gz -C "$root"
  )
  rm -rf "$tmp"
}

ensure_gfc_in_rootfs() {
  local root="$1"
  local ipk lipk
  ipk="$(find_gfc_ipk)"
  lipk="$(find_luci_ipk)"
  [[ -n "$ipk" ]] || die "gfc-client ipk not found under bin/"

  if [[ -x "$root/usr/bin/gfc-api" ]]; then
    log "rootfs already has gfc-api"
    return 0
  fi

  diagnose_missing_gfc "$root"

  log "inject gfc-client into rootfs via opkg offline-root"
  if opkg_install_ipk_into_rootfs "$root" "$ipk"; then
    :
  else
    log "opkg failed — extract ipk data.tar.gz into rootfs"
    ipkg_extract_into_rootfs "$ipk" "$root"
  fi

  if [[ -n "$lipk" ]]; then
    log "inject luci-app-gfc into rootfs"
    opkg_install_ipk_into_rootfs "$root" "$lipk" \
      || ipkg_extract_into_rootfs "$lipk" "$root"
  fi

  [[ -x "$root/usr/bin/gfc-api" ]] || die "gfc-api still missing after rootfs inject"
  log "rootfs inject OK: $root/usr/bin/gfc-api"
}

build_target_images() {
  cd "$IMT_SRC"
  require_rootfs_populated "$ROOTFS_DIR"
  log "target/linux/install (pack rootfs into images)"
  make target/linux/install -j1 V=s
  require_rootfs_populated "$ROOTFS_DIR"
}

build_image() {
  cd "$IMT_SRC"
  merge_gfc_config
  verify_dotconfig
  refresh_build_metadata
  install_rootfs

  local root
  root="$(find_rootfs_dir)"
  ensure_gfc_in_rootfs "$root"
  build_target_images
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
  load_feed_setup
  register_feed
  ensure_feeds_only
  merge_gfc_config
  verify_dotconfig
  refresh_build_metadata
  prepare_gfc_env
  build_packages
  force_rootfs
  build_image
  verify_manifest
  log "GFC firmware build OK"
}

main "$@"
