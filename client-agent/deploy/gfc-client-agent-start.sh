#!/usr/bin/env bash
# Start gfc-client-agent
set -euo pipefail
ENV_FILE="${ENV_FILE:-/etc/gfc-client/gfc.env}"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi
GFC_ROOT="${GFC_ROOT:-/opt/gfc-client}"
AGENT_DIR="${GFC_ROOT}/client-agent"
VENV="${AGENT_DIR}/.venv/bin/python"

if [[ ! -x "$VENV" ]]; then
  echo "ERROR: missing venv $VENV" >&2
  exit 1
fi

cd "$AGENT_DIR"
export PYTHONPATH="${AGENT_DIR}${PYTHONPATH:+:$PYTHONPATH}"

ARGS=(
  --state-file "${STATE_FILE:-${GFC_ROOT}/client-agent/state/client_state.json}"
  --config-dir "${CONFIG_DIR:-${GFC_ROOT}/client-agent/state/dataplane}"
  --activation-file "${ACTIVATION_FILE:-/etc/gfc-client/activation.b32}"
  --device-name "${DEVICE_NAME:-$(hostname -s)}"
  --proxy-mode "${GFC_PROXY_MODE:-gateway}"
  --poll-seconds "${POLL_SECONDS:-10}"
)
if [[ -n "${SERVER_URL:-}" ]]; then
  ARGS+=(--server "$SERVER_URL")
fi
if [[ -n "${SERVER_URL_FALLBACK:-}" ]]; then
  ARGS+=(--server-fallback "$SERVER_URL_FALLBACK")
fi

exec "$VENV" -m client_agent "${ARGS[@]}"
