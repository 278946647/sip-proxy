#!/usr/bin/env bash
# Ensure all GFC firmware packages exist in tmp/.packageinfo and gfc-client is in Kconfig.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMT_SRC="${IMT_SRC:-/opt/gfc/immortalwrt}"
INDEX="${GFC_PACKAGE_INDEX:-$ROOT/config/gfc-package-index.txt}"
FEEDS_FOR_PACKAGES=(packages luci)

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "==> $*"; }

package_in_packageinfo() {
  grep -q "^Package: ${1}$" "$IMT_SRC/tmp/.packageinfo" 2>/dev/null
}

kconfig_has_gfc_client() {
  [[ -f "$IMT_SRC/tmp/.config-package.in" ]] \
    && grep -qi 'config PACKAGE_gfc-client' "$IMT_SRC/tmp/.config-package.in"
}

read_index_packages() {
  grep -vE '^\s*(#|$)' "$INDEX" | sed 's/#.*//' | awk 'NF'
}

feeds_install_missing() {
  local pkg missing=0
  cd "$IMT_SRC"
  for feed in "${FEEDS_FOR_PACKAGES[@]}"; do
    if grep -q "^src-git ${feed} " feeds.conf 2>/dev/null \
      || grep -q "^src-link ${feed} " feeds.conf 2>/dev/null; then
      log "feeds update -i $feed"
      ./scripts/feeds update -i "$feed" || true
    fi
  done
  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] || continue
    [[ "$pkg" == "gfc-client" || "$pkg" == "luci-app-gfc" ]] && continue
    if package_in_packageinfo "$pkg"; then
      continue
    fi
    log "feeds install -f $pkg"
    ./scripts/feeds install -f "$pkg" || missing=1
  done < <(read_index_packages)
  return "$missing"
}

diagnose_gfc_client() {
  cd "$IMT_SRC"
  log "--- gfc-client in tmp/.packageinfo ---"
  awk '/^Package: gfc-client$/,/^$/' tmp/.packageinfo 2>/dev/null || echo "(absent)"
  log "--- gfc-client Makefile DEPENDS (must not reference missing packages) ---"
  grep -E '^[[:space:]]*DEPENDS' "$ROOT/package/Makefile" || true
  log "--- base DEPENDS probe ---"
  local dep
  for dep in ca-bundle ip-full nftables dnsmasq-full libcap-bin; do
    if package_in_packageinfo "$dep"; then
      log "  OK  $dep"
    else
      log "  MISS $dep"
    fi
  done
}

ensure_package_index() {
  [[ -f "$INDEX" ]] || die "missing index: $INDEX"
  cd "$IMT_SRC"
  log "prepare (package scan)"
  make -j1 V=s prepare

  if ! package_in_packageinfo gfc-client; then
    die "gfc-client not in tmp/.packageinfo — run setup-immortalwrt-feed.sh register-feed first"
  fi

  if ! kconfig_has_gfc_client; then
    log "WARN: gfc-client not in Kconfig yet — check package/Makefile DEPENDS"
    diagnose_gfc_client
  fi

  local missing=()
  local pkg
  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] || continue
    if ! package_in_packageinfo "$pkg"; then
      missing+=("$pkg")
    fi
  done < <(read_index_packages)

  if ((${#missing[@]})); then
    log "missing from packageinfo: ${missing[*]}"
    feeds_install_missing || true
    make -j1 V=s prepare
    missing=()
    while IFS= read -r pkg; do
      [[ -n "$pkg" ]] || continue
      package_in_packageinfo "$pkg" || missing+=("$pkg")
    done < <(read_index_packages)
  fi

  if ((${#missing[@]})); then
    log "still missing after feeds install: ${missing[*]}"
    log "try: cd $IMT_SRC && ./scripts/feeds update -a && ./scripts/feeds install -f ${missing[*]}"
    die "package index incomplete"
  fi

  if ! kconfig_has_gfc_client; then
    diagnose_gfc_client
    die "gfc-client still not in tmp/.config-package.in — set DEPENDS empty in package/Makefile and re-run"
  fi

  log "package index OK (${INDEX##*/})"
  log "Kconfig OK: PACKAGE_gfc-client"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  ensure_package_index
fi
