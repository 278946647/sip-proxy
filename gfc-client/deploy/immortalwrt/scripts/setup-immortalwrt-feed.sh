#!/usr/bin/env bash
# Register GFC as an ImmortalWrt src-link feed and merge package selection into .config.
# Safe to source from rebuild-gfc-image.sh (no side effects unless run as main).
set -euo pipefail

GFC_FEED_SETUP_VERSION=4

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FEED_SRC="${GFC_FEED_SRC:-$ROOT/feed}"
IMT_SRC="${IMT_SRC:-/opt/gfc/immortalwrt}"
FRAGMENT="${GFC_CONFIG_FRAGMENT:-$ROOT/config/gfc-packages.config}"

GFC_LEGACY_PATHS=(
  package/gfc
  package/gfc-client
  package/luci-app-gfc
)

usage() {
  cat <<EOF
Usage: $0 [register-feed|merge-config|verify|all]

  register-feed  Link feed, feeds update -i, feeds install -f (no .config merge)
  all            register-feed + merge gfc-packages.config (default)
  merge-config   Append CONFIG_PACKAGE_gfc-* to .config and refresh metadata
  verify         Check tmp/.packageinfo and .config for gfc-client

Environment:
  IMT_SRC       ImmortalWrt tree (default: /opt/gfc/immortalwrt)
  GFC_FEED_SRC  Feed directory with gfc-client + luci-app-gfc (default: $ROOT/feed)

Setup version: $GFC_FEED_SETUP_VERSION (must use feeds update -i + feeds install -f)
EOF
}

feed_link_line() {
  printf 'src-link gfc %s' "$FEED_SRC"
}

remove_legacy_package_gfc() {
  cd "$IMT_SRC"
  local legacy removed=0
  for legacy in "${GFC_LEGACY_PATHS[@]}"; do
    if [[ -e "$legacy" ]]; then
      echo "==> remove legacy $legacy (must use package/feeds/gfc only)"
      rm -rf "$legacy"
      removed=1
    fi
  done
  if [[ "$removed" -eq 0 ]]; then
    echo "==> no legacy package/gfc* paths"
  fi
}

normalize_feeds_conf() {
  local line tmp
  line="$(feed_link_line)"
  tmp="$(mktemp)"
  if [[ -f "$IMT_SRC/feeds.conf" ]]; then
    grep -v '^src-link gfc ' "$IMT_SRC/feeds.conf" >"$tmp" || true
  else
    : >"$tmp"
  fi
  echo "$line" >>"$tmp"
  mv "$tmp" "$IMT_SRC/feeds.conf"
  echo "==> feeds.conf gfc entry: $line"
}

ensure_feed_tree() {
  mkdir -p "$FEED_SRC"
  ln -sfn "$ROOT/package" "$FEED_SRC/gfc-client"
  ln -sfn "$ROOT/luci-app-gfc" "$FEED_SRC/luci-app-gfc"
  test -f "$FEED_SRC/gfc-client/Makefile"
  test -f "$FEED_SRC/luci-app-gfc/Makefile"
  echo "==> feed tree OK: $FEED_SRC"
}

require_feeds_install_path() {
  cd "$IMT_SRC"
  [[ -d package/feeds/gfc/gfc-client ]] \
    || { echo "ERROR: package/feeds/gfc/gfc-client missing after feeds install" >&2; exit 1; }
  [[ -d package/feeds/gfc/luci-app-gfc ]] \
    || { echo "ERROR: package/feeds/gfc/luci-app-gfc missing after feeds install" >&2; exit 1; }
  for legacy in "${GFC_LEGACY_PATHS[@]}"; do
    [[ ! -e "$legacy" ]] \
      || { echo "ERROR: legacy path still present: $legacy (blocks feeds-only rootfs)" >&2; exit 1; }
  done
  echo "==> feeds install path OK: package/feeds/gfc/{gfc-client,luci-app-gfc}"
}

refresh_packageinfo() {
  cd "$IMT_SRC"
  make -j1 V=s prepare
  grep -q 'Source-Makefile: package/feeds/gfc/gfc-client/Makefile' tmp/.packageinfo \
    || {
      echo "ERROR: packageinfo still not on feeds path:" >&2
      grep 'Source-Makefile:.*gfc-client' tmp/.packageinfo >&2 || true
      exit 1
    }
  echo "==> packageinfo on feeds path"
}

# Never run plain "feeds update gfc" or "feeds install -a" — both install feed pkgs without -f.
install_gfc_feed_packages() {
  cd "$IMT_SRC"
  echo "==> feeds update -i gfc (index only, no auto-install)"
  ./scripts/feeds update -i gfc
  echo "==> feeds install -f gfc-client luci-app-gfc"
  ./scripts/feeds install -f gfc-client luci-app-gfc
}

register_feed() {
  echo "==> GFC feed setup v${GFC_FEED_SETUP_VERSION}"
  ensure_feed_tree
  normalize_feeds_conf
  cd "$IMT_SRC"
  remove_legacy_package_gfc
  install_gfc_feed_packages
  require_feeds_install_path
  remove_legacy_package_gfc
  refresh_packageinfo
  bash "$ROOT/scripts/ensure-gfc-package-index.sh"
}

package_has_kconfig() {
  local pkg="$1"
  [[ -f "$IMT_SRC/tmp/.config-package.in" ]] \
    && grep -q "config PACKAGE_${pkg}" "$IMT_SRC/tmp/.config-package.in"
}

merge_config() {
  if [[ ! -f "$IMT_SRC/.config" ]]; then
    echo "ERROR: $IMT_SRC/.config missing — run target make defconfig first" >&2
    exit 1
  fi
  if [[ ! -f "$FRAGMENT" ]]; then
    echo "ERROR: fragment missing: $FRAGMENT" >&2
    exit 1
  fi
  cd "$IMT_SRC"
  bash "$ROOT/scripts/ensure-gfc-package-index.sh"
  local tmp merged key line pkg skipped=0
  tmp="$(mktemp)"
  merged="$(mktemp)"
  cp .config "$tmp"
  while IFS= read -r line; do
    [[ "$line" =~ ^CONFIG_PACKAGE_ ]] || continue
    key="${line%%=*}"
    pkg="${key#CONFIG_PACKAGE_}"
    if package_has_kconfig "$pkg"; then
      echo "$line" >>"$merged"
    else
      echo "==> WARN: skip $key (no Kconfig symbol — not in packageinfo or bad DEPENDS)" >&2
      skipped=$((skipped + 1))
    fi
  done <"$FRAGMENT"
  while IFS= read -r line; do
    [[ "$line" =~ ^CONFIG_PACKAGE_ ]] || continue
    key="${line%%=*}"
    grep -v "^${key}=" "$tmp" >"${tmp}.new" || true
    mv "${tmp}.new" "$tmp"
  done <"$merged"
  cat "$tmp" "$merged" >.config
  rm -f "$tmp" "$merged"
  package_has_kconfig gfc-client \
    || { echo "ERROR: CONFIG_PACKAGE_gfc-client not mergeable — fix package/Makefile DEPENDS (must be empty)" >&2; exit 1; }
  echo "==> merged $(basename "$FRAGMENT") into .config (skipped=$skipped, no oldconfig)"
}

verify() {
  local ok=0
  cd "$IMT_SRC"
  echo "==> .config"
  grep -E 'CONFIG_PACKAGE_gfc-client|CONFIG_PACKAGE_luci-app-gfc' .config || {
    echo "WARN: GFC not selected in .config"
    ok=1
  }
  echo "==> tmp/.packageinfo"
  if [[ -f tmp/.packageinfo ]]; then
    grep -i gfc-client tmp/.packageinfo || { echo "WARN: gfc-client not in packageinfo"; ok=1; }
  else
    echo "WARN: tmp/.packageinfo missing — run: make -j1 V=s prepare"
    ok=1
  fi
  echo "==> feeds tree"
  if [[ -d package/feeds/gfc/gfc-client ]]; then
    ls -la package/feeds/gfc/
  else
    echo "WARN: package/feeds/gfc missing"
    ok=1
  fi
  if [[ -f tmp/.packageinfo ]]; then
    if grep -q 'Source-Makefile: package/feeds/gfc/gfc-client/Makefile' tmp/.packageinfo; then
      grep 'Source-Makefile:.*gfc-client' tmp/.packageinfo
    else
      echo "WARN: packageinfo not on feeds path:"
      grep 'Source-Makefile:.*gfc-client' tmp/.packageinfo || true
      ok=1
    fi
  fi
  if [[ -f tmp/.config-package.in ]]; then
    if grep -qi 'config PACKAGE_gfc-client' tmp/.config-package.in; then
      grep -i 'config PACKAGE_gfc-client' tmp/.config-package.in
    else
      echo "WARN: PACKAGE_gfc-client not in Kconfig — check package/Makefile DEPENDS"
      ok=1
    fi
  fi
  for legacy in "${GFC_LEGACY_PATHS[@]}"; do
    if [[ -e "$legacy" ]]; then
      echo "WARN: legacy path still present: $legacy"
      ok=1
    fi
  done
  return "$ok"
}

gfc_feed_setup_main() {
  local cmd="${1:-all}"
  case "$cmd" in
    register-feed)
      register_feed
      verify || exit 1
      ;;
    all)
      register_feed
      merge_config
      verify || exit 1
      ;;
    merge-config)
      merge_config
      verify || exit 1
      ;;
    verify)
      verify || exit 1
      ;;
    -h|--help)
      usage
      ;;
    *)
      usage
      exit 1
      ;;
  esac

  echo ""
  echo "Next:"
  echo "  bash $ROOT/scripts/rebuild-gfc-image.sh"
  echo "  grep -i gfc $IMT_SRC/bin/targets/x86/64/*.manifest"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  gfc_feed_setup_main "$@"
fi
