#!/usr/bin/env bash
# Complete network apply after install-ubuntu (netplan was deferred to avoid SSH drop).
# Run after reconnect — prefer WAN IP (ens160), not the pre-bridge member IP.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GFC_ROOT="${GFC_ROOT:-/opt/gfc-client}"
GFC_ENV="${GFC_ENV_FILE:-/etc/gfc-client/gfc.env}"
[[ -f "$GFC_ENV" ]] && set -a && source "$GFC_ENV" && set +a

echo "==> finish-network-install"
echo "    This runs netplan apply + nft load + service start."
echo "    SSH via WAN IP if possible; netplan may drop sessions on LAN member ifaces."
echo

# Clear defer flag and force full apply
if [[ -f "$GFC_ENV" ]]; then
  if grep -q '^GFC_SKIP_NETPLAN_APPLY=' "$GFC_ENV"; then
    sed -i 's/^GFC_SKIP_NETPLAN_APPLY=.*/GFC_SKIP_NETPLAN_APPLY=0/' "$GFC_ENV"
  else
    echo 'GFC_SKIP_NETPLAN_APPLY=0' >>"$GFC_ENV"
  fi
fi

rm -f /run/gfc-client/network-applied
export GFC_FORCE_NETWORK_APPLY=1
export GFC_SKIP_NETPLAN_APPLY=0

bash "$GFC_ROOT/deploy/bootstrap-idle.sh" || echo "WARN: bootstrap-idle failed"
bash "$GFC_ROOT/deploy/gfc-network.sh" start
bash "$GFC_ROOT/deploy/start-services.sh"
bash "$GFC_ROOT/deploy/verify-install.sh"

echo
echo "==> finish-network-install done"
