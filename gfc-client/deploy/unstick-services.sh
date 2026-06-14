#!/usr/bin/env bash
# Unstick failed systemd units and restart in order (no full reinstall).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "==> unstick gfc services"
for u in gfc-network gfc-mosdns gfc-sing-box gfc-agent gfc-web dnsmasq; do
  systemctl stop "${u}.service" 2>/dev/null || true
  systemctl reset-failed "${u}.service" 2>/dev/null || true
done
bash "$SCRIPT_DIR/start-services.sh"
