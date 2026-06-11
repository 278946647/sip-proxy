#!/usr/bin/env bash
# Plan "方式 B": run node-agent in foreground from copied repo (no systemd).
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
find "$REPO_ROOT" -type f \( -name '*.sh' -o -name 'node.env' -o -name 'gfc.env' \) 2>/dev/null \
  | while IFS= read -r f; do sed -i 's/\r$//' "$f" 2>/dev/null || true; done
set -euo pipefail
ENV_FILE="${ENV_FILE:-$REPO_ROOT/deploy/node/node.env}"
AGENT_DIR="$REPO_ROOT/node-agent"

bash "$REPO_ROOT/scripts/fix-crlf.sh" "$REPO_ROOT" 2>/dev/null || true

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
fi

export SERVER_URL="${SERVER_URL:?Set SERVER_URL in deploy/node/node.env}"
export BOOTSTRAP_TOKEN="${BOOTSTRAP_TOKEN:-demo-bootstrap}"
export NODE_NAME="${NODE_NAME:-$(hostname -s)}"
export REGION="${REGION:-ap-southeast-1}"
STATE_FILE="${STATE_FILE:-$AGENT_DIR/state/node_state.json}"
CONFIG_DIR="${CONFIG_DIR:-$AGENT_DIR/state/dataplane}"
POLL_SECONDS="${POLL_SECONDS:-10}"

API="$SERVER_URL" BOOTSTRAP="$BOOTSTRAP_TOKEN" bash "$REPO_ROOT/scripts/check-prereq.sh"

mkdir -p "$(dirname "$STATE_FILE")" "$CONFIG_DIR"
cd "$AGENT_DIR"
python3 -m venv .venv
source .venv/bin/activate
pip install -q -U pip
pip install -q -r requirements.txt

exec python -m node_agent run \
  --server "$SERVER_URL" \
  --bootstrap-token "$BOOTSTRAP_TOKEN" \
  --node-name "$NODE_NAME" \
  --region "$REGION" \
  --state-file "$STATE_FILE" \
  --config-dir "$CONFIG_DIR" \
  --poll-seconds "$POLL_SECONDS"
