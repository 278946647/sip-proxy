#!/usr/bin/env bash
# Fix mosdns config (ContainerConfig-style: bad yaml / missing lists) and restart DNS stack
set -euo pipefail

GFC_ROOT="${GFC_ROOT:-/opt/gfc-client}"
SRC_ROOT="${SRC_ROOT:-/opt/sip-proxy-src/client-agent}"
if [[ -d "$SRC_ROOT/client_agent" ]]; then
  AGENT_DIR="$SRC_ROOT"
elif [[ -d "$GFC_ROOT/client-agent/client_agent" ]]; then
  AGENT_DIR="$GFC_ROOT/client-agent"
else
  echo "ERROR: client-agent source not found"
  exit 1
fi

export GFC_ETC=/etc/gfc-client
export PYTHONPATH="$AGENT_DIR"
PY="${AGENT_DIR}/.venv/bin/python"
[[ -x "$PY" ]] || PY="$(command -v python3)"

echo "==> Ensure DNS lists + rewrite mosdns.yaml"
"$PY" -c "
from client_agent.apply import apply_dns_config, reapply_local_config
ok, msg = apply_dns_config()
print(msg)
ok2, msg2 = reapply_local_config()
print(msg2)
"

echo "==> Restart services"
systemctl restart gfc-mosdns.service
sleep 1
systemctl restart gfc-client-sing-box.service 2>/dev/null || true

echo ""
systemctl is-active gfc-mosdns.service gfc-client-sing-box.service 2>/dev/null || true
echo "Done. Web: 服务管理 → DNS 分流"
