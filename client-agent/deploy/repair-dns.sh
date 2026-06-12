#!/usr/bin/env bash
# Fix mosdns config + regenerate sing-box.json and restart DNS stack
set -euo pipefail

GFC_ROOT="${GFC_ROOT:-/opt/gfc-client}"
AGENT_DIR="${GFC_ROOT}/client-agent"
export GFC_ETC=/etc/gfc-client
export PYTHONPATH="$AGENT_DIR"

PY="${AGENT_DIR}/.venv/bin/python"
[[ -x "$PY" ]] || PY="$(command -v python3)"

echo "==> Ensure DNS lists + rewrite mosdns.yaml + sing-box.json"
"$PY" -c "
from client_agent.apply import apply_dns_config, reapply_local_config
ok, msg = apply_dns_config()
print('mosdns:', msg)
ok2, msg2 = reapply_local_config()
print('full:', msg2)
if not ok2:
    raise SystemExit(1)
"

echo "==> sing-box check"
sing-box check -c /etc/gfc-client/sing-box.json

echo "==> Restart services"
systemctl restart gfc-mosdns.service
sleep 1
systemctl restart gfc-client-sing-box.service

echo ""
systemctl is-active gfc-mosdns.service gfc-client-sing-box.service
echo "Done. Web: 服务管理 → DNS 分流"
