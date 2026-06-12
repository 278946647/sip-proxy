#!/usr/bin/env bash
# Sync client-agent source -> /opt/gfc-client and verify Python imports.
set -euo pipefail

_self="${BASH_SOURCE[0]:-$0}"
_DIR="$(cd "$(dirname "$_self")" && pwd)"
CLIENT_ROOT="$(cd "$_DIR/.." && pwd)"

if [[ $EUID -ne 0 ]]; then
  echo "Run: sudo bash $0"
  exit 1
fi

GFC_ROOT="${GFC_ROOT:-/opt/gfc-client}"
AGENT_DIR="${GFC_ROOT}/client-agent"
PY="${AGENT_DIR}/.venv/bin/python"

if [[ ! -f "$CLIENT_ROOT/client_agent/easymosdns_fetch.py" ]]; then
  echo "ERROR: source tree missing easymosdns_fetch.py — run: cd /opt/sip-proxy-src && git pull origin main"
  exit 1
fi

echo "==> Sync $CLIENT_ROOT -> $GFC_ROOT"
rsync -a --delete \
  --exclude .venv --exclude state --exclude dist --exclude deploy \
  "$CLIENT_ROOT/" "$AGENT_DIR/"
rsync -a "$CLIENT_ROOT/deploy/"*.sh /usr/local/bin/
chmod +x /usr/local/bin/gfc-client-*.sh 2>/dev/null || true

if [[ -d "$CLIENT_ROOT/client-web" ]]; then
  rsync -a "$CLIENT_ROOT/client-web/" "$GFC_ROOT/client-web/"
fi

if [[ ! -x "$PY" ]]; then
  python3 -m venv "$AGENT_DIR/.venv"
  PY="${AGENT_DIR}/.venv/bin/python"
fi

"$AGENT_DIR/.venv/bin/pip" install -q -U pip setuptools wheel
"$AGENT_DIR/.venv/bin/pip" install -q -r "$AGENT_DIR/requirements.txt"
"$AGENT_DIR/.venv/bin/pip" install -q -e "$AGENT_DIR"

echo "==> Verify easymosdns_fetch present"
grep -q easymosdns_fetch "$AGENT_DIR/client_agent/easymosdns_config.py"

echo "==> Verify Python imports"
cd "$AGENT_DIR"
PYTHONPATH="$AGENT_DIR" "$PY" -c "
from client_agent.apply import reapply_local_config, apply_dns_config
from client_agent.web_server import main
from client_agent.easymosdns_fetch import fetch
print('import ok')
"

echo "Sync complete: $AGENT_DIR"
