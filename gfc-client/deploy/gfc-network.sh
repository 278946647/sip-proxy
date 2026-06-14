#!/usr/bin/env bash
# GFC network bootstrap: resolved, resolv.conf, sysctl, netplan, nftables
set -euo pipefail

GFC_ROOT="${GFC_ROOT:-/opt/gfc-client}"
GFC_ETC="${GFC_ETC:-/etc/gfc-client}"
GFC_ENV="${GFC_ENV_FILE:-/etc/gfc-client/gfc.env}"
APPLY_NETWORK="${GFC_ROOT}/deploy/apply-network.sh"

[[ -f "$GFC_ENV" ]] && set -a && source "$GFC_ENV" && set +a

disable_resolved() {
  if systemctl is-enabled systemd-resolved &>/dev/null; then
    systemctl disable --now systemd-resolved || true
  elif systemctl is-active systemd-resolved &>/dev/null; then
    systemctl stop systemd-resolved || true
  fi
  if [[ -L /etc/resolv.conf ]]; then
    rm -f /etc/resolv.conf
  fi
  chattr -i /etc/resolv.conf 2>/dev/null || true
  cat >/etc/resolv.conf <<'EOF'
nameserver 127.0.0.1
EOF
  chmod 644 /etc/resolv.conf
}

start() {
  echo "==> gfc-network start"
  disable_resolved
  sysctl -p /etc/sysctl.d/99-gfc-client.conf >/dev/null 2>&1 || sysctl -w net.ipv4.ip_forward=1 >/dev/null
  if [[ -x "$APPLY_NETWORK" ]]; then
    bash "$APPLY_NETWORK"
  else
    echo "WARN: apply-network.sh missing at $APPLY_NETWORK"
  fi
}

stop() {
  echo "==> gfc-network stop (no-op)"
}

case "${1:-start}" in
  start) start ;;
  stop) stop ;;
  *) echo "usage: $0 {start|stop}"; exit 1 ;;
esac
