#!/usr/bin/env bash
# Reapply active dataplane (mosdns + sing-box) when line code already activated.
set -euo pipefail

_self="${BASH_SOURCE[0]:-$0}"
_DIR="$(cd "$(dirname "$_self")" && pwd)"
GFC_ROOT="${GFC_ROOT:-/opt/gfc-client}"
AGENT_DIR="${GFC_ROOT}/client-agent"
PY="${AGENT_DIR}/.venv/bin/python"
[[ -x "$PY" ]] || PY="$(command -v python3)"

if [[ $EUID -ne 0 ]]; then
  echo "Run: sudo bash $0"
  exit 1
fi

bash "$_DIR/sync-code.sh"
bash "$_DIR/repair-mosdns.sh"

systemctl stop gfc-client-agent 2>/dev/null || true

echo "==> Reapply active dataplane"
cd "$AGENT_DIR"
PYTHONPATH="$AGENT_DIR" export GFC_ETC=/etc/gfc-client
PYTHONPATH="$AGENT_DIR" "$PY" -c "
from client_agent.activation import is_line_activated
from client_agent.apply import reapply_local_config, restart_dataplane_services
from client_agent.bootstrap import ensure_services_running

if is_line_activated():
    ok, msg = reapply_local_config()
    print(msg)
    if not ok:
        raise SystemExit(1)
    print(restart_dataplane_services())
else:
    from client_agent.bootstrap import ensure_bootstrap_dataplane
    ok, msg = ensure_bootstrap_dataplane(try_download=True)
    print(msg)
    if not ok:
        raise SystemExit(1)
ensure_services_running()
"

sing-box check -c /etc/gfc-client/sing-box.json
systemctl is-active gfc-mosdns gfc-client-sing-box gfc-client-agent
ip link show gfc0 2>/dev/null || echo "WARN: gfc0 not up — check sing-box logs"
dig @127.0.0.1 -p 5335 github.com +short +time=3 | head -3 || true
