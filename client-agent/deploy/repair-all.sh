#!/usr/bin/env bash
# One-shot repair: sync code, stop agent (avoid config overwrite), fix DNS/sing-box/web :81
set -euo pipefail

_self="${BASH_SOURCE[0]:-$0}"
_DIR="$(cd "$(dirname "$_self")" && pwd)"
CLIENT_ROOT="$(cd "$_DIR/.." && pwd)"

if [[ $EUID -ne 0 ]]; then
  echo "Run: sudo bash $0"
  exit 1
fi

echo "======== GFC Client repair-all ========"
echo "==> Stop agent (prevent overwriting sing-box.json during repair)"
systemctl stop gfc-client-agent 2>/dev/null || true
systemctl stop gfc-client-flash 2>/dev/null || true
systemctl disable gfc-client-flash 2>/dev/null || true
systemctl mask gfc-client-flash 2>/dev/null || true

echo "==> repair-web"
bash "$_DIR/repair-web.sh"

echo "==> repair-dns + sing-box"
bash "$_DIR/repair-dns.sh"

echo "==> easymosdns rules (CDN, bootstrap DNS 223.5.5.5)"
GFC_ROOT="${GFC_ROOT:-/opt/gfc-client}"
AGENT_DIR="${GFC_ROOT}/client-agent"
export PYTHONPATH="$AGENT_DIR"
PY="${AGENT_DIR}/.venv/bin/python"
if "$PY" -c "from client_agent.easymosdns_update import update_easymosdns_rules; update_easymosdns_rules('cdn')" 2>/dev/null; then
  echo "    easymosdns rules updated"
else
  echo "    WARN: easymosdns update skipped (no network) — use Web DNS 分流 later"
fi

echo "==> Start agent"
systemctl start gfc-client-agent

echo ""
echo "======== Summary ========"
systemctl is-active gfc-client-web gfc-mosdns gfc-client-sing-box gfc-client-agent 2>/dev/null || true
ss -lntup | grep -E ':80 |:81 ' || true
sing-box check -c /etc/gfc-client/sing-box.json
echo ""
echo "Web: http://192.168.68.1/services.html  Flash: http://192.168.68.1:81/"
