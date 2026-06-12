#!/usr/bin/env bash
# GFC client line-code flash UI (port 81)
set -euo pipefail
ENV_FILE="${ENV_FILE:-/etc/gfc-client/gfc.env}"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi
GFC_ROOT="${GFC_ROOT:-/opt/gfc-client}"
VENV="${GFC_ROOT}/client-agent/.venv/bin/python"
WEB_ROOT="${GFC_CLIENT_WEB_ROOT:-${GFC_ROOT}/client-web}"
WEB_PORT="${GFC_CLIENT_FLASH_PORT:-81}"

exec "$VENV" -m client_agent.web_server --mode flash --port "$WEB_PORT" --root "$WEB_ROOT"
