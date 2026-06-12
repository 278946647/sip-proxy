#!/usr/bin/env bash
# Fix mosdns: remove legacy v5 yaml, install mosdns-x, regenerate easymosdns config.
set -euo pipefail

_self="${BASH_SOURCE[0]:-$0}"
_DIR="$(cd "$(dirname "$_self")" && pwd)"

if [[ $EUID -ne 0 ]]; then
  echo "Run: sudo bash $0"
  exit 1
fi

GFC_ROOT="${GFC_ROOT:-/opt/gfc-client}"
AGENT_DIR="${GFC_ROOT}/client-agent"
PY="${AGENT_DIR}/.venv/bin/python"
[[ -x "$PY" ]] || PY="$(command -v python3)"

echo "==> Remove legacy mosdns v5 config"
rm -f /etc/gfc-client/mosdns.yaml
rm -f /etc/gfc-client/mosdns/easymosdns/config.yaml.bak

echo "==> Install mosdns-x"
FORCE_MOSDNS_X=1 bash "$_DIR/upgrade-mosdns-x.sh"
bash "$_DIR/fix-mosdns-unit.sh"

systemctl stop gfc-mosdns 2>/dev/null || true

echo "==> Regenerate easymosdns config"
cd "$AGENT_DIR"
export PYTHONPATH="$AGENT_DIR"
export GFC_ETC=/etc/gfc-client
"$PY" -c "
from client_agent.easymosdns_config import (
    MOSDNS_CONFIG,
    mosdns_binary_ok,
    mosdns_config_ok,
    remove_legacy_mosdns_files,
    render_mosdns_config_file,
)
remove_legacy_mosdns_files()
ok, msg = mosdns_binary_ok()
print('binary:', msg)
if not ok:
    raise SystemExit(1)
render_mosdns_config_file(try_download=True)
ok, msg = mosdns_config_ok(MOSDNS_CONFIG)
print('config:', msg)
if not ok:
    raise SystemExit(1)
"

systemctl restart gfc-mosdns
sleep 1
systemctl is-active gfc-mosdns
ss -lntup | grep 5335 || { tail -20 /var/log/gfc-client/mosdns.log; exit 1; }
echo "mosdns OK on :5335"
