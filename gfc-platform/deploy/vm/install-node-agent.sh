#!/usr/bin/env bash
set -euo pipefail

SERVER_URL="${SERVER_URL:-http://control-plane:8080}"
BOOTSTRAP_TOKEN="${BOOTSTRAP_TOKEN:-demo-bootstrap}"
NODE_NAME="${NODE_NAME:-$(hostname)}"
REGION="${REGION:-unknown}"

INSTALL_DIR="${INSTALL_DIR:-/opt/gfc-node-agent}"
VENV_DIR="${INSTALL_DIR}/.venv"
STATE_DIR="${INSTALL_DIR}/state"

echo "Installing to ${INSTALL_DIR}"
sudo mkdir -p "${INSTALL_DIR}"
sudo chown -R "$(id -u)":"$(id -g)" "${INSTALL_DIR}"

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required"
  exit 1
fi

python3 -m venv "${VENV_DIR}"
source "${VENV_DIR}/bin/activate"

pip install --upgrade pip
pip install -r "${INSTALL_DIR}/requirements.txt"

mkdir -p "${STATE_DIR}"

cat > "${INSTALL_DIR}/node-agent.env" <<EOF
SERVER_URL=${SERVER_URL}
BOOTSTRAP_TOKEN=${BOOTSTRAP_TOKEN}
NODE_NAME=${NODE_NAME}
REGION=${REGION}
EOF

echo "Done. Next: install systemd unit from deploy/vm/node-agent.service"

