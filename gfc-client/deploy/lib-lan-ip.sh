#!/usr/bin/env bash
# Resolve LAN IP on bridge_lan (or configured GFC_LAN_IFACE).

gfc_lan_ip() {
  local env="${GFC_ENV_FILE:-/etc/gfc-client/gfc.env}"
  local iface ip
  if [[ -f "$env" ]]; then
    # shellcheck disable=SC1090
    source "$env" 2>/dev/null || true
  fi
  iface="${GFC_LAN_IFACE:-${GFC_BRIDGE_NAME:-bridge_lan}}"
  ip="${GFC_LAN_ADDRESS:-}"
  if [[ -z "$ip" ]]; then
    ip=$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
  fi
  printf '%s' "${ip:-unknown}"
}

gfc_lan_iface() {
  local env="${GFC_ENV_FILE:-/etc/gfc-client/gfc.env}"
  if [[ -f "$env" ]]; then
    # shellcheck disable=SC1090
    source "$env" 2>/dev/null || true
  fi
  printf '%s' "${GFC_LAN_IFACE:-${GFC_BRIDGE_NAME:-bridge_lan}}"
}
