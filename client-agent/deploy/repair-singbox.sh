#!/usr/bin/env bash
set -euo pipefail
GFC_ROOT="${GFC_ROOT:-/opt/gfc-client}"
AGENT_DIR="${GFC_ROOT}/client-agent"
export GFC_ETC=/etc/gfc-client
export PYTHONPATH="$AGENT_DIR"
PY="${AGENT_DIR}/.venv/bin/python"
[[ -x "$PY" ]] || PY="$(command -v python3)"

systemctl stop gfc-client-agent 2>/dev/null || true

echo "==> Regenerate sing-box.json"
"$PY" -c "
from client_agent.apply import reapply_local_config
ok, msg = reapply_local_config()
print(msg)
if not ok:
    raise SystemExit(1)
"

sing-box check -c /etc/gfc-client/sing-box.json
systemctl restart gfc-client-sing-box.service
systemctl is-active gfc-client-sing-box.service
echo "Done."
