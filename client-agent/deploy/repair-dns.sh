#!/usr/bin/env bash
# Fix mosdns + sing-box.json (stop agent first if not already stopped)
set -euo pipefail

GFC_ROOT="${GFC_ROOT:-/opt/gfc-client}"
AGENT_DIR="${GFC_ROOT}/client-agent"
export GFC_ETC=/etc/gfc-client
export PYTHONPATH="$AGENT_DIR"

PY="${AGENT_DIR}/.venv/bin/python"
[[ -x "$PY" ]] || PY="$(command -v python3)"

systemctl stop gfc-client-agent 2>/dev/null || true

echo "==> Rewrite mosdns.yaml + sing-box.json"
"$PY" -c "
from client_agent.apply import reapply_local_config
ok, msg = reapply_local_config()
print(msg)
if not ok:
    raise SystemExit(1)
"

echo "==> sing-box check"
sing-box check -c /etc/gfc-client/sing-box.json

echo "==> Restart mosdns + sing-box"
systemctl restart gfc-mosdns.service
sleep 1
systemctl restart gfc-client-sing-box.service
sleep 1

systemctl is-active gfc-mosdns.service gfc-client-sing-box.service
echo "Done."
