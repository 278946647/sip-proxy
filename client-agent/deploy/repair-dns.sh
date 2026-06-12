#!/usr/bin/env bash
set -euo pipefail

_self="${BASH_SOURCE[0]:-$0}"
_DIR="$(cd "$(dirname "$_self")" && pwd)"
CLIENT_ROOT="$(cd "$_DIR/.." && pwd)"

GFC_ROOT="${GFC_ROOT:-/opt/gfc-client}"
AGENT_DIR="${GFC_ROOT}/client-agent"
export GFC_ETC=/etc/gfc-client
PY="${AGENT_DIR}/.venv/bin/python"
[[ -x "$PY" ]] || PY="$(command -v python3)"

if [[ -f "$CLIENT_ROOT/client_agent/__init__.py" ]]; then
  echo "==> Sync client-agent -> $GFC_ROOT"
  rsync -a "$CLIENT_ROOT/client_agent/" "$AGENT_DIR/client_agent/"
  cp -f "$CLIENT_ROOT/setup.py" "$CLIENT_ROOT/requirements.txt" "$AGENT_DIR/" 2>/dev/null || true
  if [[ -x "$AGENT_DIR/.venv/bin/pip" ]]; then
    "$AGENT_DIR/.venv/bin/pip" install -q -e "$AGENT_DIR"
  fi
fi

echo "==> mosdns-x (easymosdns requires mosdns-x, not v5)"
bash "$_DIR/upgrade-mosdns-x.sh" || echo "WARN: mosdns-x upgrade skipped"

systemctl stop gfc-client-agent 2>/dev/null || true

echo "==> Bootstrap / reapply dataplane"
cd "$AGENT_DIR"
PYTHONPATH="$AGENT_DIR" "$PY" -c "
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
