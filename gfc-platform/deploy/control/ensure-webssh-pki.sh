#!/usr/bin/env bash
# Ensure control-plane WebSSH keypair exists inside the API container volume.
# Usage (from gfc-platform root, as root):
#   sudo bash deploy/control/ensure-webssh-pki.sh
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$_SCRIPT_DIR/../.." && pwd)"
# shellcheck source=deploy/control/compose-util.sh
source "$_SCRIPT_DIR/compose-util.sh"

cd "$ROOT"
gfc_compose_ensure_webssh_pki "$ROOT"
echo ""
echo "验证 WebSSH（示例端口 6001，按设备实际 reverse_ssh_port 调整）:"
echo "  CID=\$(docker ps -qf label=com.docker.compose.service=api)"
echo "  docker exec \$CID ssh -i /data/pki/webssh_id -p 6001 -o BatchMode=yes -o StrictHostKeyChecking=no root@127.0.0.1 uname -a"
