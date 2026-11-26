#!/usr/bin/env bash
# Register the AmneziaWG source package feed into the ImmortalWrt build tree.
#
# Source: https://github.com/Slava-Shchipunov/awg-openwrt (referenced by the
# official Amnezia docs). The repo root ships package Makefiles for
# kmod-amneziawg / amneziawg-tools, so the kernel module is compiled against
# THIS tree's kernel — no foreign vermagic, kmod mainline only (no userspace awgm).
#
# Idempotent: re-running replaces the feed line and reinstalls.
# Reversible:  --remove detaches the feed without touching the gfc feed.
set -euo pipefail

IMT_SRC="${IMT_SRC:-/opt/gfc/immortalwrt}"
AWG_FEED_NAME="${AWG_FEED_NAME:-awg}"
AWG_FEED_SRC="${AMNEZIAWG_FEED_SRC:-https://github.com/Slava-Shchipunov/awg-openwrt}"
AWG_FEED_LINE="src-git ${AWG_FEED_NAME} ${AWG_FEED_SRC}"
REQUIRED_PACKAGES=(kmod-amneziawg amneziawg-tools)

log() { echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $0 [install|--remove]

  install   Register the AWG feed, install its packages, refresh Kconfig (default)
  --remove  Detach the AWG feed and its symlinks (gfc feed untouched)

Environment:
  IMT_SRC            ImmortalWrt tree (default: /opt/gfc/immortalwrt)
  AMNEZIAWG_FEED_SRC Feed git URL (default: $AWG_FEED_SRC)
  AWG_FEED_NAME      Feed name (default: awg)
EOF
}

[[ -d "$IMT_SRC" ]] || die "ImmortalWrt tree not found: $IMT_SRC"
[[ -x "$IMT_SRC/scripts/feeds" ]] || die "scripts/feeds missing in $IMT_SRC"

FEEDS_CONF="$IMT_SRC/feeds.conf"
[[ -f "$FEEDS_CONF" ]] || : >"$FEEDS_CONF"

drop_feed_line() {
  local tmp
  tmp="$(mktemp)"
  grep -v -E "^src-git[[:space:]]+${AWG_FEED_NAME}[[:space:]]" "$FEEDS_CONF" >"$tmp" || true
  mv "$tmp" "$FEEDS_CONF"
}

remove_feed() {
  drop_feed_line
  rm -rf "${IMT_SRC}/package/feeds/${AWG_FEED_NAME}" "${IMT_SRC}/feeds/${AWG_FEED_NAME}"
  (
    cd "$IMT_SRC"
    ./scripts/feeds update >/dev/null 2>&1 || true
  )
  log "removed feed '${AWG_FEED_NAME}' from $FEEDS_CONF (gfc feed untouched)"
  log "next: bash scripts/rebuild-gfc-image.sh will no longer require AWG packages"
}

install_feed() {
  drop_feed_line
  echo "$AWG_FEED_LINE" >>"$FEEDS_CONF"
  log "feeds.conf: $AWG_FEED_LINE"

  cd "$IMT_SRC"
  log "feeds update ${AWG_FEED_NAME}"
  ./scripts/feeds update "${AWG_FEED_NAME}"
  log "feeds install -a ${AWG_FEED_NAME}"
  ./scripts/feeds install -a "${AWG_FEED_NAME}"
  log "refresh packageinfo (make prepare)"
  make -j1 V=s prepare >/dev/null 2>&1 || true

  local missing=()
  for pkg in "${REQUIRED_PACKAGES[@]}"; do
    if ! grep -q "config PACKAGE_${pkg}" tmp/.config-package.in 2>/dev/null; then
      missing+=("$pkg")
    fi
  done
  if ((${#missing[@]})); then
    die "feed registered but Kconfig still missing: ${missing[*]}
   -> check feed/kernel compatibility:
      ls package/feeds/${AWG_FEED_NAME}
      grep -R 'config PACKAGE_${AWG_FEED_NAME}' tmp/.config-package.in | head"
  fi
  log "OK: ${REQUIRED_PACKAGES[*]} now selectable"
  log "next: bash \$GFC_REPO/deploy/immortalwrt/scripts/rebuild-gfc-image.sh"
}

case "${1:-install}" in
  install) install_feed ;;
  --remove | remove) remove_feed ;;
  -h | --help) usage ;;
  *) usage; exit 1 ;;
esac
