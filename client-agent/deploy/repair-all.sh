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
GFC_ROOT="${GFC_ROOT:-/opt/gfc-client}"
AGENT_DIR="${GFC_ROOT}/client-agent"
PY="${AGENT_DIR}/.venv/bin/python"
[[ -x "$PY" ]] || PY="$(command -v python3)"

echo "==> Stop agent (prevent overwriting sing-box.json during repair)"
systemctl stop gfc-client-agent 2>/dev/null || true
systemctl unmask gfc-client-flash 2>/dev/null || true

echo "==> repair-web"
bash "$_DIR/repair-web.sh"

echo "==> repair-dns + bootstrap dataplane"
bash "$_DIR/repair-dns.sh"

echo "==> apply LAN bridge (bridge_lan)"
cd "$AGENT_DIR" && PYTHONPATH="$AGENT_DIR" "$PY" -c "from client_agent.network import apply_network; ok, msg = apply_network(); print(msg); exit(0 if ok else 1)"

echo "==> easymosdns rules (CDN, bootstrap DNS 223.5.5.5)"
if cd "$AGENT_DIR" && PYTHONPATH="$AGENT_DIR" "$PY" -c "from client_agent.easymosdns_update import update_easymosdns_rules; update_easymosdns_rules('cdn')" 2>/dev/null; then
  echo "    easymosdns rules updated"
else
  echo "    WARN: easymosdns update skipped (no network) — use Web DNS 分流 later"
fi

echo "==> Start agent"
systemctl start gfc-client-agent

echo ""
echo "======== Summary ========"
systemctl is-active gfc-client-web gfc-client-flash gfc-mosdns gfc-client-sing-box gfc-client-agent 2>/dev/null || true
ss -lntup | grep -E ':80 |:81 ' || true
if [[ -f /etc/gfc-client/sing-box.json ]]; then
  sing-box check -c /etc/gfc-client/sing-box.json
else
  echo "sing-box: skipped (no line code / sing-box.json)"
fi
ip -br addr show bridge_lan 2>/dev/null || true
echo ""
echo "Web: http://192.168.68.1/services.html  Flash: http://192.168.68.1:81/"
