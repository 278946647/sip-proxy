#!/usr/bin/env bash
# Register GFC as an ImmortalWrt src-link feed and merge package selection into .config.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FEED_SRC="${GFC_FEED_SRC:-$ROOT/feed}"
IMT_SRC="${IMT_SRC:-/opt/gfc/immortalwrt}"
FRAGMENT="${GFC_CONFIG_FRAGMENT:-$ROOT/config/gfc-packages.config}"

usage() {
  cat <<EOF
Usage: $0 [merge-config|verify|all]

  all           Link feed, feeds install, merge gfc-packages.config (default)
  merge-config  Append CONFIG_PACKAGE_gfc-* to .config and refresh metadata
  verify        Check tmp/.packageinfo and .config for gfc-client

Environment:
  IMT_SRC       ImmortalWrt tree (default: /opt/gfc/immortalwrt)
  GFC_FEED_SRC  Feed directory with gfc-client + luci-app-gfc (default: $ROOT/feed)
EOF
}

feed_link_line() {
  printf 'src-link gfc %s' "$FEED_SRC"
}

ensure_feed_tree() {
  mkdir -p "$FEED_SRC"
  ln -sfn "$ROOT/package" "$FEED_SRC/gfc-client"
  ln -sfn "$ROOT/luci-app-gfc" "$FEED_SRC/luci-app-gfc"
  test -f "$FEED_SRC/gfc-client/Makefile"
  test -f "$FEED_SRC/luci-app-gfc/Makefile"
}

register_feed() {
  ensure_feed_tree
  local line
  line="$(feed_link_line)"
  if ! grep -qF "$line" "$IMT_SRC/feeds.conf" 2>/dev/null; then
    echo "$line" >>"$IMT_SRC/feeds.conf"
    echo "==> added to feeds.conf: $line"
  else
    echo "==> feeds.conf already has gfc src-link"
  fi
  cd "$IMT_SRC"
  ./scripts/feeds update gfc
  ./scripts/feeds install -a
  ./scripts/feeds install gfc-client luci-app-gfc
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
  # Refresh package metadata so Kconfig knows gfc-client (invalid DEPENDS used to drop symbols)
  make -j1 V=s prepare 2>/dev/null || make -j1 V=s 2>/dev/null || true
  local tmp
  tmp="$(mktemp)"
  grep -vE 'CONFIG_PACKAGE_gfc-client|CONFIG_PACKAGE_luci-app-gfc' .config >"$tmp" || true
  cat "$tmp" "$FRAGMENT" >.config
  rm -f "$tmp"
  if ! grep -q 'CONFIG_PACKAGE_gfc-client=y' .config; then
    echo "CONFIG_PACKAGE_gfc-client=y" >>.config
  fi
  if ! grep -q 'CONFIG_PACKAGE_luci-app-gfc=y' .config; then
    echo "CONFIG_PACKAGE_luci-app-gfc=y" >>.config
  fi
  yes '' | make oldconfig 2>/dev/null || yes '' | make menuconfig_prepare 2>/dev/null || true
  echo "==> merged $(basename "$FRAGMENT") into .config"
}

verify() {
  cd "$IMT_SRC"
  echo "==> .config"
  grep -E 'CONFIG_PACKAGE_gfc-client|CONFIG_PACKAGE_luci-app-gfc' .config || {
    echo "WARN: GFC not selected in .config"
  }
  echo "==> tmp/.packageinfo"
  if [[ -f tmp/.packageinfo ]]; then
    grep -i gfc-client tmp/.packageinfo || echo "WARN: gfc-client not in packageinfo"
  else
    echo "WARN: tmp/.packageinfo missing — run: make -j1 V=s prepare"
  fi
  echo "==> feeds tree"
  ls -la package/feeds/gfc/ 2>/dev/null || ls -la package/gfc/ 2>/dev/null || echo "WARN: no gfc package path"
}

cmd="${1:-all}"
case "$cmd" in
  all)
    register_feed
    merge_config
    verify
    ;;
  merge-config) merge_config; verify ;;
  verify) verify ;;
  -h|--help) usage ;;
  *) usage; exit 1 ;;
esac

echo ""
echo "Next: make package/gfc-client/compile V=s GFC_CLIENT_SRC=<path-to-gfc-client>"
echo "      grep -i gfc bin/targets/x86/64/*.manifest"
