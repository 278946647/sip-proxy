#!/usr/bin/env bash
# Start gfc-client-agent with env from /etc/gfc-client/gfc.env
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
exec "$VENV" -m client_agent \
  --state-file "${STATE_FILE:-${GFC_ROOT}/client-agent/state/client_state.json}" \
  --config-dir "${CONFIG_DIR:-${GFC_ROOT}/client-agent/state/dataplane}" \
  --activation-file "${ACTIVATION_FILE:-/etc/gfc-client/activation.b32}" \
  --device-name "${DEVICE_NAME:-$(hostname -s)}" \
  --proxy-mode "${GFC_PROXY_MODE:-gateway}" \
  --poll-seconds "${POLL_SECONDS:-10}" \
  ${SERVER_URL:+--server "$SERVER_URL"}
