#!/usr/bin/env bash
# Start GFC services in dependency order (network → dns prep → mosdns → sing-box → agent → web).
set -euo pipefail

GFC_ROOT="${GFC_ROOT:-/opt/gfc-client}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

start_one() {
  local unit=$1
  local timeout_sec=${2:-45}
  echo "    start ${unit} (timeout ${timeout_sec}s)..."
  if timeout "$timeout_sec" systemctl start "$unit"; then
    echo "    ${unit}: $(systemctl is-active "$unit" 2>/dev/null || echo unknown)"
    return 0
  fi
  echo "    WARN: ${unit} failed"
  journalctl -u "$unit" -n 15 --no-pager 2>/dev/null || true
  return 1
}

echo "==> start-services (ordered)"

# Layer 1: network oneshot (marks active; script may no-op if stamp exists)
start_one gfc-network.service 30 || echo "    WARN: gfc-network unit not active"

# Layer 2: DHCP only (optional)
if systemctl list-unit-files dnsmasq.service &>/dev/null; then
  timeout 20 systemctl start dnsmasq.service 2>/dev/null || echo "    WARN: dnsmasq optional start failed"
fi

# Layer 3: nftables already loaded by gfc-network script; no separate unit

# Layer 4: DNS — prepare then MosDNS
if [[ -x "$SCRIPT_DIR/ensure-dns.sh" ]]; then
  bash "$SCRIPT_DIR/ensure-dns.sh" || echo "    WARN: ensure-dns had issues"
fi
start_one gfc-mosdns.service 45 || true

# Layer 5: traffic plane
start_one gfc-sing-box.service 30 || true

# Layer 6: management plane (Wants data plane; should start even if sing-box idle)
start_one gfc-agent.service 30 || true
start_one gfc-web.service 30 || true

echo "==> start-services done"
systemctl is-active gfc-network gfc-mosdns gfc-sing-box gfc-agent gfc-web 2>/dev/null || true
