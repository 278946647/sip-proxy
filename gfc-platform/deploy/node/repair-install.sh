#!/usr/bin/env bash
# Re-run installer pieces on an already-installed node (sing-box 404, missing state file).
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=deploy/node/_common.sh
source "$(cd "$(dirname "$0")" && pwd)/_common.sh"
if gfc_fix_crlf_file "$0"; then exec bash "$0" "$@"; fi
gfc_fix_crlf_tree "$REPO_ROOT"
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "sudo bash $0"
  exit 1
fi

if [[ -f /etc/gfc-node/gfc.env ]]; then
  set -a
  # shellcheck source=/dev/null
  source /etc/gfc-node/gfc.env
  set +a
fi

export REPO_SRC="${REPO_SRC:-$REPO_ROOT}"
export SERVER_URL="${SERVER_URL:?Set SERVER_URL in /etc/gfc-node/gfc.env}"
export BOOTSTRAP_TOKEN="${BOOTSTRAP_TOKEN:-demo-bootstrap}"
export NODE_NAME="${NODE_NAME:-$(hostname -s)}"
export REGION="${REGION:-ap-southeast-1}"
export GFC_TPROXY_IFACE="${GFC_TPROXY_IFACE:-}"

echo "==> Repair: re-run install-ubuntu.sh (idempotent)"
bash "$REPO_ROOT/deploy/node/install-ubuntu.sh"
bash "$REPO_ROOT/deploy/node/verify-node.sh"
