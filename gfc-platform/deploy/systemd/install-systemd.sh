#!/usr/bin/env bash
# Install systemd units for API + Web UI (boot on startup)
set -euo pipefail

ROOT="${GFC_ROOT:-/var/socks}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$ROOT/logs"

_LOGROTATE="$SCRIPT_DIR/../scripts/install-logrotate.sh"
if [[ -f "$_LOGROTATE" ]]; then
  bash "$_LOGROTATE" control "$ROOT/logs"
  install -m 755 "$SCRIPT_DIR/../scripts/gfc-logs.sh" /usr/local/bin/gfc-logs 2>/dev/null || true
fi

# Ensure venv exists
if [[ ! -d "$ROOT/control-plane/api/.venv" ]]; then
  python3 -m venv "$ROOT/control-plane/api/.venv"
  "$ROOT/control-plane/api/.venv/bin/pip" install -r "$ROOT/control-plane/api/requirements.txt"
fi

if [[ ! -d "$ROOT/web-ui/node_modules" ]]; then
  cd "$ROOT/web-ui" && npm install
fi

if [[ ! -f "$ROOT/gfc.env" ]]; then
  cp "$ROOT/scripts/gfc.env.example" "$ROOT/gfc.env"
  echo "Created $ROOT/gfc.env — please review SERVER_URL / NODE_NAME"
fi

cp "$SCRIPT_DIR/gfc-api.service" /etc/systemd/system/
cp "$SCRIPT_DIR/gfc-web.service" /etc/systemd/system/
cp "$SCRIPT_DIR/gfc-node.service" /etc/systemd/system/

# Ensure node agent venv
if [[ ! -d "$ROOT/node-agent/.venv" ]]; then
  python3 -m venv "$ROOT/node-agent/.venv"
  "$ROOT/node-agent/.venv/bin/pip" install -r "$ROOT/node-agent/requirements.txt"
fi

systemctl daemon-reload
systemctl enable gfc-api gfc-web gfc-node
systemctl restart gfc-api gfc-web gfc-node

echo "Installed. Status:"
systemctl status gfc-api --no-pager -l | head -3
systemctl status gfc-web --no-pager -l | head -3
systemctl status gfc-node --no-pager -l | head -3
echo ""
echo "API:  http://<IP>:8080/healthz"
echo "Web:  http://<IP>:5173"
