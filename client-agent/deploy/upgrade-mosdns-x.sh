#!/usr/bin/env bash
# Upgrade mosdns v5 -> mosdns-x (required for easymosdns config)
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run: sudo bash $0"
  exit 1
fi

MOSDNS_X_VERSION="${MOSDNS_X_VERSION:-26.05.25}"
arch="$(uname -m)"
case "$arch" in
  x86_64) MOS_ARCH=amd64 ;;
  aarch64 | arm64) MOS_ARCH=arm64 ;;
  *)
    echo "Unsupported arch: $arch"
    exit 1
    ;;
esac

if command -v mosdns >/dev/null 2>&1; then
  ver="$(mosdns version 2>/dev/null || true)"
  if [[ -n "$ver" ]] && ! echo "$ver" | grep -qE '^v?5\.'; then
    echo "mosdns already mosdns-x: $ver"
    exit 0
  fi
  echo "Current mosdns: ${ver:-unknown} — upgrading to mosdns-x ${MOSDNS_X_VERSION}"
else
  echo "mosdns not found — installing mosdns-x ${MOSDNS_X_VERSION}"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
installed=0
for asset in "mosdns-linux-${MOS_ARCH}.zip" "mosdns-x-linux-${MOS_ARCH}.zip"; do
  url="https://github.com/pmkol/mosdns-x/releases/download/v${MOSDNS_X_VERSION}/${asset}"
  echo "Try: $url"
  if curl -fsSL --connect-timeout 20 --max-time 120 --dns-servers 223.5.5.5 "$url" -o "$tmp/mosdns.zip" 2>/dev/null; then
    unzip -q "$tmp/mosdns.zip" -d "$tmp"
    bin="$(find "$tmp" -name mosdns -type f | head -1)"
    if [[ -n "$bin" ]]; then
      install -m 755 "$bin" /usr/local/bin/mosdns
      installed=1
      break
    fi
  fi
done

if [[ "$installed" -ne 1 ]]; then
  echo "ERROR: failed to download mosdns-x — check network/DNS"
  exit 1
fi

mosdns version
echo "mosdns-x installed."
