#!/usr/bin/env bash
# Start GFC services in dependency order (network → dns prep → mosdns → sing-box → agent → web).
set -euo pipefail

GFC_ROOT="${GFC_ROOT:-/opt/gfc-client}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GFC_ENV="${GFC_ENV_FILE:-/etc/gfc-client/gfc.env}"
[[ -f "$GFC_ENV" ]] && set -a && source "$GFC_ENV" && set +a
LAN_IFACE="${GFC_LAN_IFACE:-${GFC_BRIDGE_NAME:-bridge_lan}}"
TUN_IFACE="${GFC_TUN_INTERFACE:-gfctun}"

# shellcheck source=lib-gfc-mode.sh
source "$SCRIPT_DIR/lib-gfc-mode.sh"

reset_units() {
  for u in gfc-network gfc-mosdns gfc-sing-box gfc-routing gfc-agent gfc-web; do
    systemctl stop "${u}.service" 2>/dev/null || true
    systemctl reset-failed "${u}.service" 2>/dev/null || true
  done
}

start_one() {
  local unit=$1
  local timeout_sec=${2:-45}
  echo "    start ${unit} (timeout ${timeout_sec}s)..."
  if timeout "$timeout_sec" systemctl start "$unit"; then
    echo "    ${unit}: $(systemctl is-active "$unit" 2>/dev/null || echo unknown)"
    return 0
  fi
  echo "    WARN: ${unit} failed"
  journalctl -u "$unit" -n 20 --no-pager 2>/dev/null || true
  return 1
}

ensure_idle_configs() {
  if [[ -f /etc/gfc-client/sing-box.json && -f /etc/gfc-client/mosdns/easymosdns/config.yaml ]]; then
    return 0
  fi
  echo "    idle configs missing — bootstrap..."
  bash "$SCRIPT_DIR/bootstrap-idle.sh"
}

echo "==> start-services (ordered)"
ensure_idle_configs
reset_units

# Layer 1: network (script does real work; unit marks RemainAfterExit)
echo "    layer 1: network"
bash "$SCRIPT_DIR/gfc-network.sh" start || echo "    WARN: gfc-network script failed"
start_one gfc-network.service 60 || echo "    WARN: gfc-network unit not active"

# Layer 2: DHCP only (enable done at install; here only start)
if [[ "${GFC_SKIP_NETPLAN_APPLY:-0}" == "1" ]]; then
  echo "    dnsmasq: deferred (finish-network-install.sh)"
elif ! ip link show "$LAN_IFACE" &>/dev/null; then
  echo "    dnsmasq: deferred (${LAN_IFACE} not up)"
else
  if systemctl list-unit-files dnsmasq.service &>/dev/null; then
    timeout 20 systemctl start dnsmasq.service 2>/dev/null || echo "    WARN: dnsmasq optional start failed"
  fi
fi

# Layer 4: DNS prep then MosDNS (Layer 3 nft loaded by network script)
echo "    layer 4: dns"
bash "$SCRIPT_DIR/ensure-dns.sh" || echo "    WARN: ensure-dns had issues"
bash "$SCRIPT_DIR/fix-mosdns-start.sh" || echo "    WARN: fix-mosdns-start had issues"

# Layer 5: sing-box + routing only after line code / TUN config
if gfc_need_proxy_dataplane; then
  echo "    layer 5: sing-box + routing"
  start_one gfc-sing-box.service 30 || true
  if [[ "${GFC_SKIP_NETPLAN_APPLY:-0}" == "1" ]]; then
    echo "    gfc-routing: deferred (finish-network-install.sh)"
  elif ! ip link show "$TUN_IFACE" &>/dev/null; then
    echo "    gfc-routing: deferred (${TUN_IFACE} not up — reapply after line code)"
  else
    start_one gfc-routing.service 45 || true
  fi
else
  echo "    layer 5: proxy skipped (router-only until flash + reapply)"
  systemctl stop gfc-sing-box gfc-routing 2>/dev/null || true
  systemctl reset-failed gfc-sing-box gfc-routing 2>/dev/null || true
  bash "$SCRIPT_DIR/gfc-routing.sh" start 2>/dev/null || true
fi

# Layer 6: management plane
echo "    layer 6: agent + web"
start_one gfc-agent.service 30 || true
start_one gfc-web.service 30 || true

echo "==> start-services done"
systemctl is-active gfc-network gfc-mosdns gfc-sing-box gfc-routing gfc-agent gfc-web 2>/dev/null || true
