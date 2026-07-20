#!/usr/bin/env bash
# Ensure GFC firmware packages exist in tmp/.packageinfo and gfc-client is in Kconfig.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMT_SRC="${IMT_SRC:-/opt/gfc/immortalwrt}"
INDEX="${GFC_PACKAGE_INDEX:-$ROOT/config/gfc-package-index.txt}"

# OpenWrt base tree (package/) — NOT installable via feeds; only verify after prepare.
BASE_TREE_PACKAGES=(
  ca-bundle ip-full dnsmasq-full kmod-tun kmod-nft-core
  nftables-json nftables-nojson
  tc-tiny kmod-sched-core kmod-ifb
  kmod-tcp-bbr kmod-sched
  # resize2fs is a separate OpenWrt package (not e2fsprogs);
  # partx binary is in partx-utils (util-linux); losetup for wiki resize path
  resize2fs partx-utils losetup
)

# GFC src-link feed
GFC_FEED_PACKAGES=(gfc-client luci-app-gfc)

# packages / luci feeds
FEED_PACKAGES=(
  sing-box unbound-daemon unbound-checkconf autossh libcap-bin luci-base
  curl wget-ssl tcpdump iftop bmon
  # GNU parted lives in packages feed (not package/utils/parted)
  parted
)

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "==> $*"; }

read_index_packages() {
  grep -vE '^\s*(#|$)' "$INDEX" | sed 's/#.*//' | awk 'NF'
}

package_in_packageinfo() {
  grep -q "^Package: ${1}$" "$IMT_SRC/tmp/.packageinfo" 2>/dev/null
}

# Resolve logical names (e.g. nftables) to actual package names in modern OpenWrt.
resolve_package_candidates() {
  local name=$1
  case "$name" in
    nftables) printf '%s\n' nftables-json nftables-nojson ;;
    # HTB qdisc is built into kmod-sched-core; no standalone kmod-sched-htb.
    kmod-sched-htb) printf '%s\n' kmod-sched-core ;;
    # util-linux subpackage name is partx-utils (provides partx binary).
    partx) printf '%s\n' partx-utils ;;
    *) printf '%s\n' "$name" ;;
  esac
}

package_available() {
  local name=$1 candidate
  while IFS= read -r candidate; do
    package_in_packageinfo "$candidate" && return 0
  done < <(resolve_package_candidates "$name")
  # PROVIDES alias (e.g. nftables-json Provides: nftables)
  grep -qE "^Provides:.*(^|[[:space:]])${name}([[:space:]]|$$)" "$IMT_SRC/tmp/.packageinfo" 2>/dev/null \
    && return 0
  return 1
}

is_base_tree_package() {
  local name=$1 candidate
  while IFS= read -r candidate; do
    local p
    for p in "${BASE_TREE_PACKAGES[@]}"; do
      [[ "$candidate" == "$p" ]] && return 0
    done
  done < <(resolve_package_candidates "$name")
  return 1
}

is_gfc_feed_package() {
  local p
  for p in "${GFC_FEED_PACKAGES[@]}"; do
    [[ "$1" == "$p" ]] && return 0
  done
  return 1
}

kconfig_has_gfc_client() {
  [[ -f "$IMT_SRC/tmp/.config-package.in" ]] \
    && grep -qi 'config PACKAGE_gfc-client' "$IMT_SRC/tmp/.config-package.in"
}

feeds_update_feeds() {
  cd "$IMT_SRC"
  local feed
  for feed in packages luci; do
    if grep -qE "^src-(git|link) ${feed} " feeds.conf 2>/dev/null; then
      log "feeds update -i $feed"
      ./scripts/feeds update -i "$feed" || true
    fi
  done
}

feeds_install_pkg() {
  local pkg=$1
  log "feeds install -f $pkg"
  ./scripts/feeds install -f "$pkg" || return 1
}

diagnose_missing() {
  local name=$1
  log "diagnose missing: $name"
  if is_base_tree_package "$name"; then
    log "  category: OpenWrt base tree (not a feed package)"
    log "  try: grep -i '${name}' $IMT_SRC/tmp/.packageinfo | head"
    log "  try: ls $IMT_SRC/package/network/utils/nftables 2>/dev/null"
    if [[ "$name" == "nftables" || "$name" == nftables-* ]]; then
      log "  note: use nftables-json or nftables-nojson in gfc-packages.config (no Package: nftables)"
    fi
    if [[ "$name" == "kmod-sched-htb" ]]; then
      log "  note: use kmod-sched-core (includes sch_htb); no Package: kmod-sched-htb"
    fi
  else
    log "  category: packages/luci feed"
    log "  try: cd $IMT_SRC && ./scripts/feeds search $name"
  fi
}

ensure_package_index() {
  [[ -f "$INDEX" ]] || die "missing index: $INDEX"
  cd "$IMT_SRC"

  log "prepare (package scan)"
  make -j1 V=s prepare

  if ! package_in_packageinfo gfc-client; then
    die "gfc-client not in tmp/.packageinfo — run setup-immortalwrt-feed.sh register-feed first"
  fi

  local missing=() pkg
  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] || continue
    package_available "$pkg" || missing+=("$pkg")
  done < <(read_index_packages)

  if ((${#missing[@]})); then
    log "missing from packageinfo: ${missing[*]}"
    feeds_update_feeds
    for pkg in "${missing[@]}"; do
      if is_gfc_feed_package "$pkg"; then
        log "skip feeds install for $pkg (gfc feed — run setup-immortalwrt-feed.sh)"
        continue
      fi
      if is_base_tree_package "$pkg"; then
        diagnose_missing "$pkg"
        continue
      fi
      feeds_install_pkg "$pkg" || true
    done
    make -j1 V=s prepare
    missing=()
    while IFS= read -r pkg; do
      [[ -n "$pkg" ]] || continue
      package_available "$pkg" || missing+=("$pkg")
    done < <(read_index_packages)
  fi

  if ((${#missing[@]})); then
    for pkg in "${missing[@]}"; do
      diagnose_missing "$pkg"
    done
    die "package index incomplete: ${missing[*]}"
  fi

  if ! kconfig_has_gfc_client; then
    log "gfc-client missing from Kconfig"
    grep -E '^[[:space:]]*DEPENDS' "$ROOT/package/Makefile" || true
    die "set DEPENDS empty in package/Makefile, run setup-immortalwrt-feed.sh, then retry"
  fi

  log "package index OK (${INDEX##*/})"
  log "Kconfig OK: PACKAGE_gfc-client"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  ensure_package_index
fi
