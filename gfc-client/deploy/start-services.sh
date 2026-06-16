#!/usr/bin/env bash
# Start GFC services in dependency order (network → dns prep → mosdns → sing-box → agent → web).
set -euo pipefail

GFC_ROOT="${GFC_ROOT:-/opt/gfc-client}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

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

echo "==> start-services (ordered)"
reset_units

# Layer 1: network (script does real work; unit marks RemainAfterExit)
echo "    layer 1: network"
bash "$SCRIPT_DIR/gfc-network.sh" start || echo "    WARN: gfc-network script failed"
start_one gfc-network.service 60 || echo "    WARN: gfc-network unit not active"

# Layer 2: DHCP only (enable done at install; here only start)
if systemctl list-unit-files dnsmasq.service &>/dev/null; then
  timeout 20 systemctl start dnsmasq.service 2>/dev/null || echo "    WARN: dnsmasq optional start failed"
fi

# Layer 4: DNS prep then MosDNS (Layer 3 nft loaded by network script)
echo "    layer 4: dns"
bash "$SCRIPT_DIR/ensure-dns.sh" || echo "    WARN: ensure-dns had issues"
start_one gfc-mosdns.service 45 || true

# Layer 5: sing-box (outbound engine) + kernel policy routing
echo "    layer 5: sing-box + routing"
start_one gfc-sing-box.service 30 || true
start_one gfc-routing.service 45 || true

# Layer 6: management plane
echo "    layer 6: agent + web"
start_one gfc-agent.service 30 || true
start_one gfc-web.service 30 || true

echo "==> start-services done"
systemctl is-active gfc-network gfc-mosdns gfc-sing-box gfc-routing gfc-agent gfc-web 2>/dev/null || true
