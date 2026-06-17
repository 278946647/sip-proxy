#!/usr/bin/env bash
# Remove sing-box auto_redirect nft tables when the proxy is stopped or idle.
set -euo pipefail

TUN="${GFC_TUN_INTERFACE:-gfctun}"

command -v nft >/dev/null || exit 0

for family in inet ip ip6; do
  for name in sing-box singbox; do
    if nft list table "$family" "$name" &>/dev/null; then
      nft delete table "$family" "$name" 2>/dev/null || true
    fi
  done
done

while read -r family name; do
  [[ -z "${family:-}" || -z "${name:-}" ]] && continue
  case "$name" in
    *sing-box*|*singbox*)
      nft delete table "$family" "$name" 2>/dev/null || true
      ;;
  esac
done < <(nft list tables 2>/dev/null | awk '{print $2, $3}')

# Stale gfctun after crash/restart prevents sing-box from coming back up.
if ip link show "$TUN" &>/dev/null; then
  if ! pgrep -x sing-box >/dev/null 2>&1; then
    ip link del "$TUN" 2>/dev/null || true
  fi
fi
