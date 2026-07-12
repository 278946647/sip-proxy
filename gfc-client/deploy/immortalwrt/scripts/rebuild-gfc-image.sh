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
# Image/Manifest + squashfs/ext4 are built from TARGET_DIR_ORIG, NOT TARGET_DIR.
# package/install does: opkg install → CP TARGET_DIR → TARGET_DIR_ORIG → prepare_rootfs(TARGET_DIR)
ROOTFS_ORIG_DIR="${ROOTFS_ORIG_DIR:-${TARGET_BUILD}/root.orig-x86}"
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
  grep -q 'GFC_FEED_SETUP_VERSION=4' "$GFC_FEED_SETUP" \
    || die "outdated setup script (need v4). Run: cd /opt/gfc/sip-proxy && git pull"
  grep -q 'feeds update -i gfc' "$GFC_FEED_SETUP" \
    || die "setup script missing feeds update -i — git pull sip-proxy on build machine"
}

load_feed_setup() {
  require_feed_setup_script
  # shellcheck disable=SC1090
  source "$GFC_FEED_SETUP"
}

ensure_gfc_package_index() {
  bash "$GFC_DEPLOY/scripts/ensure-gfc-package-index.sh"
}

merge_gfc_config() {
  local fragment="$GFC_DEPLOY/config/gfc-packages.config"
  [[ -f "$IMT_SRC/.config" ]] || die "missing $IMT_SRC/.config"
  [[ -f "$fragment" ]] || die "missing $fragment"
  cd "$IMT_SRC"
  ensure_gfc_package_index
  local tmp merged key line pkg
  tmp="$(mktemp)"
  merged="$(mktemp)"
  cp .config "$tmp"
  while IFS= read -r line; do
    [[ "$line" =~ ^CONFIG_PACKAGE_ ]] || continue
    key="${line%%=*}"
    pkg="${key#CONFIG_PACKAGE_}"
    if grep -q "config PACKAGE_${pkg}" tmp/.config-package.in 2>/dev/null; then
      echo "$line" >>"$merged"
    else
      log "WARN: skip $key (no Kconfig symbol)"
    fi
  done <"$fragment"
  while IFS= read -r line; do
    [[ "$line" =~ ^CONFIG_PACKAGE_ ]] || continue
    key="${line%%=*}"
    grep -v "^${key}=" "$tmp" >"${tmp}.new" || true
    mv "${tmp}.new" "$tmp"
  done <"$merged"
  cat "$tmp" "$merged" >.config
  rm -f "$tmp" "$merged"
  grep -q '^CONFIG_PACKAGE_gfc-client=y$' .config || die "CONFIG_PACKAGE_gfc-client not in .config after merge"
}

# OpenWrt image install list comes from Kconfig package-y + pkginfo/*.install.
refresh_build_metadata() {
  ensure_gfc_package_index
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
  ensure_gfc_client_pkginfo
}

ensure_gfc_client_pkginfo() {
  local pkginfo="$STAGING_PKGINFO/gfc-client.default.install"
  cd "$IMT_SRC"
  # Always rewrite: older scripts wrongly wrote a file listing here.
  if [[ -f "$pkginfo" ]] && grep -qx 'gfc-client' "$pkginfo"; then
    log "pkginfo OK: $pkginfo"
  else
    log "fix/write gfc-client.default.install (must be package name, not file list)"
    synthesize_gfc_client_default_install
  fi
  grep -qx 'gfc-client' "$pkginfo" || die "gfc-client.default.install must contain exactly package name 'gfc-client'"
}

find_rootfs_dir() {
  if [[ -d "$ROOTFS_DIR" ]]; then
    printf '%s\n' "$ROOTFS_DIR"
    return 0
  fi
  find "$TARGET_BUILD" -maxdepth 1 -type d -name 'root-*' 2>/dev/null | head -1
}

detect_opkg_arch() {
  if [[ -n "${GFC_OPKG_ARCH:-}" ]]; then
    printf '%s\n' "$GFC_OPKG_ARCH"
    return 0
  fi
  local cfg="$IMT_SRC/.config"
  if [[ -f "$cfg" ]]; then
    local arch
    arch="$(grep -E '^CONFIG_TARGET_ARCH_PACKAGES=' "$cfg" | cut -d= -f2- | tr -d '"')"
    [[ -n "$arch" ]] && { printf '%s\n' "$arch"; return 0; }
    grep -q '^CONFIG_x86_64=y' "$cfg" && { printf '%s\n' x86_64; return 0; }
  fi
  printf '%s\n' x86_64
}

prepare_ipk_for_opkg() {
  local ipk=$1
  if head -c 8 "$ipk" | grep -q '^!<arch>'; then
    printf '%s\n' "$ipk"
    return 0
  fi
  if tar tf "$ipk" debian-binary >/dev/null 2>&1; then
    printf '%s\n' "$ipk"
    return 0
  fi
  if file -b "$ipk" | grep -qi '^gzip compressed'; then
    local tmp
    tmp="$(mktemp /tmp/gfc-ipk.XXXXXX)"
    gunzip -c "$ipk" >"$tmp"
    printf '%s\n' "$tmp"
    return 0
  fi
  printf '%s\n' "$ipk"
}

rootfs_has_gfc_opkg() {
  local root=$1
  [[ -f "$root/usr/lib/opkg/info/gfc-client.control" ]] \
    || grep -q '^Package: gfc-client$' "$root/usr/lib/opkg/status" 2>/dev/null
}

synthesize_gfc_client_default_install() {
  # OpenWrt PACKAGE_INSTALL_FILES: each *.default.install contains PACKAGE NAMES
  # (one per line), NOT a file listing. package/Makefile does:
  #   opkg install $(opkg_package_files $(cat *.install))
  local out="$STAGING_PKGINFO/gfc-client.default.install"
  mkdir -p "$STAGING_PKGINFO"
  printf '%s\n' gfc-client >"$out"
  log "wrote $out (package name only — required for opkg_install_list)"
}

validate_ipk() {
  local ipk="$1"
  [[ -f "$ipk" ]] || die "ipk not found: $ipk"
  [[ -s "$ipk" ]] || die "ipk empty (compile may have failed): $ipk"
  if ! file -b "$ipk" | grep -qiE 'ar archive|debian|gzip|tar|zip'; then
    die "ipk not a valid archive: $ipk ($(file -b "$ipk"))"
  fi
}

find_newest_ipk() {
  local pattern=$1
  find "$IMT_SRC/bin" -name "$pattern" -type f -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | head -1 | cut -d' ' -f2-
}

find_gfc_ipk() {
  local ipk
  ipk="$(find_newest_ipk 'gfc-client_*.ipk')"
  [[ -n "$ipk" ]] || return 1
  validate_ipk "$ipk"
  printf '%s\n' "$ipk"
}

find_luci_ipk() {
  local ipk
  ipk="$(find_newest_ipk 'luci-app-gfc_*.ipk')"
  [[ -n "$ipk" ]] || return 1
  validate_ipk "$ipk"
  printf '%s\n' "$ipk"
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
  log "package/install -> populate $ROOTFS_DIR (+ snapshot $ROOTFS_ORIG_DIR)"
  make package/install -j1 V=s
  require_rootfs_populated "$ROOTFS_DIR"
  [[ -d "$ROOTFS_ORIG_DIR" ]] || die "missing $ROOTFS_ORIG_DIR after package/install (Image/Manifest uses ORIG)"
  if grep -qE 'gfc-client_.*\.ipk' "$IMT_SRC/tmp/opkg_install_list" 2>/dev/null; then
    log "opkg_install_list includes gfc-client ipk"
  else
    log "WARN: gfc-client still missing from opkg_install_list — will inject into TARGET_DIR + ORIG"
  fi
}

# Manifest + images come from TARGET_DIR_ORIG. Inject must update BOTH trees.
sync_gfc_into_orig() {
  local root=$1
  local orig="${2:-$ROOTFS_ORIG_DIR}"
  [[ -d "$orig" ]] || die "ORIG rootfs missing: $orig"
  log "sync gfc from $(basename "$root") → $(basename "$orig") (required for Image/Manifest)"
  mkdir -p "$orig/usr/bin" "$orig/usr/lib" "$orig/etc" "$orig/usr/lib/opkg/info"
  for bin in gfc-api gfc-agent gfc-bootstrap; do
    [[ -f "$root/usr/bin/$bin" ]] && cp -a "$root/usr/bin/$bin" "$orig/usr/bin/$bin"
  done
  [[ -d "$root/usr/lib/gfc-client" ]] && rm -rf "$orig/usr/lib/gfc-client" && cp -a "$root/usr/lib/gfc-client" "$orig/usr/lib/"
  [[ -d "$root/etc/gfc-client" ]] && rm -rf "$orig/etc/gfc-client" && cp -a "$root/etc/gfc-client" "$orig/etc/"
  [[ -d "$root/etc/init.d" ]] && for s in gfc-api gfc-agent gfc-unbound gfc-sing-box gfc-routing; do
    [[ -f "$root/etc/init.d/$s" ]] && cp -a "$root/etc/init.d/$s" "$orig/etc/init.d/$s"
  done
  if [[ -f "$root/usr/lib/opkg/info/gfc-client.control" ]]; then
    cp -a "$root/usr/lib/opkg/info/gfc-client".* "$orig/usr/lib/opkg/info/" 2>/dev/null || true
  fi
  if grep -q '^Package: gfc-client$' "$root/usr/lib/opkg/status" 2>/dev/null; then
    if ! grep -q '^Package: gfc-client$' "$orig/usr/lib/opkg/status" 2>/dev/null; then
      awk '
        BEGIN { keep=0 }
        /^Package: gfc-client$/ { keep=1 }
        keep { print }
        keep && /^$/ { exit }
      ' "$root/usr/lib/opkg/status" >>"$orig/usr/lib/opkg/status"
    fi
  fi
  rootfs_has_gfc_opkg "$orig" || die "ORIG still missing gfc-client opkg after sync"
  [[ -x "$orig/usr/bin/gfc-api" ]] || die "ORIG still missing gfc-api after sync"
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
  local arch prepared cleanup=0
  arch="$(detect_opkg_arch)"
  [[ -x "$opkg" ]] || die "host opkg missing: $opkg"
  validate_ipk "$ipk"
  prepared="$(prepare_ipk_for_opkg "$ipk")"
  [[ "$prepared" != "$ipk" ]] && cleanup=1
  log "opkg install $(basename "$ipk") arch=${arch} offline-root=$root"
  mkdir -p "$root/tmp"
  IPKG_NO_SCRIPT=1 IPKG_INSTROOT="$root" TMPDIR="$root/tmp" \
    "$opkg" --offline-root "$root" \
      --force-postinstall --force-overwrite --force-depends \
      --add-dest root:/ \
      --add-arch "all:100" \
      --add-arch "${arch}:200" \
      install "$prepared"
  local rc=$?
  (( cleanup )) && rm -f "$prepared"
  return "$rc"
}

ipkg_is_tar_archive() {
  file -b "$1" | grep -qiE 'tar archive|POSIX tar'
}

ipkg_unpack_members() {
  local ipk=$1 tmp=$2
  if head -c 8 "$ipk" | grep -q '^!<arch>'; then
    ( cd "$tmp" && ar x "$ipk" )
    return 0
  fi
  # ImmortalWrt ipk: gzip outer -> GNU tar(debian-binary, control.tar.*, data.tar.*)
  if ipkg_is_tar_archive "$ipk"; then
    tar xf "$ipk" -C "$tmp"
    return 0
  fi
  if tar tf "$ipk" 2>/dev/null | grep -qE '(^|/)debian-binary$'; then
    tar xf "$ipk" -C "$tmp"
    return 0
  fi
  die "cannot unpack ipk (not ar or tar): $ipk ($(file -b "$ipk"))"
}

ipkg_extract_data_into_rootfs() {
  local data=$1 root=$2
  case "$data" in
    *.tar.gz|*.tgz) tar xzf "$data" -C "$root" ;;
    *.tar.zst|*.tzst)
      if command -v zstd >/dev/null 2>&1; then
        zstd -dc "$data" | tar xf - -C "$root"
      elif [[ -x "$IMT_SRC/staging_dir/host/bin/zstd" ]]; then
        "$IMT_SRC/staging_dir/host/bin/zstd" -dc "$data" | tar xf - -C "$root"
      else
        die "data.tar.zst needs zstd: $data"
      fi
      ;;
    *.tar.xz|*.txz) tar xJf "$data" -C "$root" ;;
    *) die "unsupported data member: $data" ;;
  esac
}

ipkg_list_data_files() {
  local data=$1
  case "$data" in
    *.tar.gz|*.tgz) tar tzf "$data" ;;
    *.tar.zst|*.tzst)
      if command -v zstd >/dev/null 2>&1; then
        zstd -dc "$data" | tar tf -
      else
        "$IMT_SRC/staging_dir/host/bin/zstd" -dc "$data" | tar tf -
      fi
      ;;
    *.tar.xz|*.txz) tar tJf "$data" ;;
    *) die "unsupported data member for list: $data" ;;
  esac
}

register_opkg_metadata_from_ipk() {
  local ipk=$1 root=$2
  local tmp prepared ctrl_tmp cleanup=0
  local pkg ver arch depends info_dir
  tmp="$(mktemp -d)"
  prepared="$(prepare_ipk_for_opkg "$ipk")"
  [[ "$prepared" != "$ipk" ]] && cleanup=1
  ipkg_unpack_members "$prepared" "$tmp"
  shopt -s nullglob
  local controls=( "$tmp"/control.tar.* "$tmp"/*/control.tar.* )
  local data_members=( "$tmp"/data.tar.* "$tmp"/*/data.tar.* )
  shopt -u nullglob
  ((${#controls[@]})) || die "no control.tar.* in $ipk"
  ctrl_tmp="$(mktemp -d)"
  case "${controls[0]}" in
    *.tar.gz|*.tgz) tar xzf "${controls[0]}" -C "$ctrl_tmp" ;;
    *.tar.zst|*.tzst)
      if command -v zstd >/dev/null 2>&1; then
        zstd -dc "${controls[0]}" | tar xf - -C "$ctrl_tmp"
      else
        "$IMT_SRC/staging_dir/host/bin/zstd" -dc "${controls[0]}" | tar xf - -C "$ctrl_tmp"
      fi
      ;;
    *.tar.xz|*.txz) tar xJf "${controls[0]}" -C "$ctrl_tmp" ;;
    *) die "unsupported control member: ${controls[0]}" ;;
  esac
  [[ -f "$ctrl_tmp/control" ]] || die "control file missing in $ipk"
  pkg="$(awk -F': ' '/^Package:/{print $2; exit}' "$ctrl_tmp/control")"
  ver="$(awk -F': ' '/^Version:/{print $2; exit}' "$ctrl_tmp/control")"
  arch="$(awk -F': ' '/^Architecture:/{print $2; exit}' "$ctrl_tmp/control")"
  depends="$(awk -F': ' '/^Depends:/{print $2; exit}' "$ctrl_tmp/control")"
  [[ -n "$pkg" && -n "$ver" ]] || die "invalid control in $ipk"
  info_dir="$root/usr/lib/opkg/info"
  mkdir -p "$info_dir"
  cp "$ctrl_tmp/control" "$info_dir/${pkg}.control"
  : >"$info_dir/${pkg}.list"
  for data in "${data_members[@]}"; do
    [[ -f "$data" ]] || continue
    ipkg_list_data_files "$data" >>"$info_dir/${pkg}.list"
  done
  if ! grep -q "^Package: ${pkg}$" "$root/usr/lib/opkg/status" 2>/dev/null; then
    {
      echo "Package: $pkg"
      echo "Version: $ver"
      echo "Depends: ${depends:-}"
      echo "Status: install ok installed"
      echo "Architecture: ${arch:-$(detect_opkg_arch)}"
      echo "Installed-Time: $(date +%s)"
      echo
    } >>"$root/usr/lib/opkg/status"
  fi
  rm -rf "$ctrl_tmp" "$tmp"
  (( cleanup )) && rm -f "$prepared"
  log "opkg metadata registered from ipk: $pkg $ver"
}

ipkg_extract_into_rootfs() {
  local ipk="$1" root="$2"
  local tmp prepared data cleanup=0
  tmp="$(mktemp -d)"
  prepared="$(prepare_ipk_for_opkg "$ipk")"
  [[ "$prepared" != "$ipk" ]] && cleanup=1
  ipkg_unpack_members "$prepared" "$tmp"
  shopt -s nullglob
  local members=( "$tmp"/data.tar.* "$tmp"/*/data.tar.* )
  shopt -u nullglob
  for data in "${members[@]}"; do
    [[ -f "$data" ]] || continue
    ipkg_extract_data_into_rootfs "$data" "$root"
    rm -rf "$tmp"
    (( cleanup )) && rm -f "$prepared"
    return 0
  done
  rm -rf "$tmp"
  (( cleanup )) && rm -f "$prepared"
  die "ipk has no data.tar.* member: $ipk"
}

ensure_gfc_in_rootfs() {
  local root="$1"
  local ipk lipk
  ipk="$(find_gfc_ipk)" || die "gfc-client ipk not found under bin/ (run build_packages first)"
  lipk="$(find_luci_ipk 2>/dev/null || true)"

  # Prefer native install path: if ORIG already has opkg metadata, package/install succeeded.
  if rootfs_has_gfc_opkg "$ROOTFS_ORIG_DIR" && [[ -x "$ROOTFS_ORIG_DIR/usr/bin/gfc-api" ]]; then
    log "ORIG already has gfc-client (native package/install) — OK for manifest"
    return 0
  fi

  if rootfs_has_gfc_opkg "$root" && [[ -x "$root/usr/bin/gfc-api" ]]; then
    log "TARGET_DIR has gfc; syncing to ORIG for Image/Manifest"
    sync_gfc_into_orig "$root" "$ROOTFS_ORIG_DIR"
    return 0
  fi

  diagnose_missing_gfc "$root"
  cd "$IMT_SRC"

  log "register gfc-client via opkg into TARGET_DIR (arch=$(detect_opkg_arch))"
  if ! opkg_install_ipk_into_rootfs "$root" "$ipk"; then
    log "opkg install failed — extract + register metadata"
    if [[ ! -x "$root/usr/bin/gfc-api" ]]; then
      ipkg_extract_into_rootfs "$ipk" "$root"
    fi
    register_opkg_metadata_from_ipk "$ipk" "$root"
  fi

  if [[ -n "$lipk" ]] && ! grep -q '^Package: luci-app-gfc$' "$root/usr/lib/opkg/status" 2>/dev/null; then
    log "register luci-app-gfc via opkg"
    opkg_install_ipk_into_rootfs "$root" "$lipk" \
      || { ipkg_extract_into_rootfs "$lipk" "$root"; register_opkg_metadata_from_ipk "$lipk" "$root"; }
  fi

  [[ -x "$root/usr/bin/gfc-api" ]] || die "gfc-api still missing after rootfs inject"
  rootfs_has_gfc_opkg "$root" \
    || die "gfc-api present but opkg status missing on TARGET_DIR"
  sync_gfc_into_orig "$root" "$ROOTFS_ORIG_DIR"
  log "rootfs OK: gfc-api + opkg on TARGET_DIR and ORIG"
}

regenerate_manifest_from_orig() {
  local orig="$ROOTFS_ORIG_DIR"
  local manifest="$IMT_SRC/bin/targets/x86/64/immortalwrt-x86-64-generic.manifest"
  local opkg="$IMT_SRC/staging_dir/host/bin/opkg"
  local arch
  arch="$(detect_opkg_arch)"
  [[ -x "$opkg" ]] || die "host opkg missing"
  [[ -d "$orig" ]] || die "ORIG missing for manifest regenerate"
  mkdir -p "$(dirname "$manifest")"
  log "regenerate manifest via opkg list-installed on ORIG"
  IPKG_NO_SCRIPT=1 IPKG_INSTROOT="$orig" TMPDIR="$orig/tmp" \
    "$opkg" --offline-root "$orig" \
      --add-dest root:/ \
      --add-arch "all:100" \
      --add-arch "${arch}:200" \
      list-installed >"$manifest"
  grep -q gfc-client "$manifest" || die "regenerated manifest still missing gfc-client"
}

build_target_images() {
  cd "$IMT_SRC"
  require_rootfs_populated "$ROOTFS_DIR"
  rootfs_has_gfc_opkg "$ROOTFS_ORIG_DIR" \
    || die "ORIG missing gfc-client before image build — Image/Manifest would omit it"
  log "target/linux/install (pack ORIG rootfs into images)"
  make target/linux/install -j1 V=s
  require_rootfs_populated "$ROOTFS_DIR"
  # Belt-and-suspenders: OpenWrt Image/Manifest reads ORIG; rewrite if race/stale.
  if ! grep -q gfc-client "$IMT_SRC/bin/targets/x86/64/"*.manifest 2>/dev/null; then
    log "WARN: image build manifest missing gfc-client — regenerating from ORIG"
    regenerate_manifest_from_orig
  fi
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
  local root orig
  root="$(find_rootfs_dir)"
  orig="$ROOTFS_ORIG_DIR"
  [[ -f "$manifest" ]] || die "missing $manifest"
  log "TARGET_DIR: $(test -x "$root/usr/bin/gfc-api" && echo has gfc-api || echo NO gfc-api)"
  log "ORIG: $(rootfs_has_gfc_opkg "$orig" && echo gfc-client registered || echo NO gfc-client opkg)"
  if ! grep -q gfc-client "$manifest"; then
    log "manifest stale — regenerate from ORIG"
    regenerate_manifest_from_orig
  fi
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
