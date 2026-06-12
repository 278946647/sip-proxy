#!/usr/bin/env bash
set -euo pipefail

GFC_ROOT="${GFC_ROOT:-/opt/gfc-client}"
AGENT_DIR="${GFC_ROOT}/client-agent"
export GFC_ETC=/etc/gfc-client
export PYTHONPATH="$AGENT_DIR"
PY="${AGENT_DIR}/.venv/bin/python"
[[ -x "$PY" ]] || PY="$(command -v python3)"

systemctl stop gfc-client-agent 2>/dev/null || true

echo "==> Bootstrap / reapply dataplane"
"$PY" -c "
from client_agent.apply import reapply_local_config
from client_agent.bootstrap import ensure_services_running
ok, msg = reapply_local_config()
print(msg)
if not ok:
    raise SystemExit(1)
ensure_services_running()
"

if [[ -f /etc/gfc-client/sing-box.json ]]; then
  sing-box check -c /etc/gfc-client/sing-box.json
fi

systemctl is-active gfc-mosdns gfc-client-sing-box gfc-client-web gfc-client-flash 2>/dev/null || true
echo "Done."
