#!/usr/bin/env bash
# Install logrotate + journald caps for GFC (control plane and/or forward node).
# Usage:
#   sudo bash deploy/scripts/install-logrotate.sh control [/var/socks/logs]
#   sudo bash deploy/scripts/install-logrotate.sh forward
#   sudo bash deploy/scripts/install-logrotate.sh all [/var/socks/logs]
set -euo pipefail

MODE="${1:-all}"
CP_LOG_DIR="${2:-/var/socks/logs}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash $0 ..."
  exit 1
fi

if ! command -v logrotate >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq logrotate
fi

install_control() {
  local dir="$1"
  mkdir -p "$dir"
  sed "s|@LOG_DIR@|${dir}|g" "$DEPLOY_ROOT/logrotate/gfc-control-plane.conf" \
    >/etc/logrotate.d/gfc-control-plane
  echo "OK logrotate control plane -> $dir (*.log, ~1 day, max 50M per file before rotate)"
}

install_forward() {
  local dir="/var/log/gfc-node"
  mkdir -p "$dir"
  chmod 755 "$dir"
  sed "s|@LOG_DIR@|${dir}|g" "$DEPLOY_ROOT/logrotate/gfc-forward-node.conf" \
    >/etc/logrotate.d/gfc-forward-node
  install -d -m 755 /etc/systemd/journald.conf.d
  cp "$DEPLOY_ROOT/journald/gfc-forward-node.conf" /etc/systemd/journald.conf.d/gfc-forward-node.conf
  systemctl restart systemd-journald 2>/dev/null || true
  echo "OK logrotate forward node -> $dir + journald MaxRetentionSec=1day SystemMaxUse=300M"
}

case "$MODE" in
  control) install_control "$CP_LOG_DIR" ;;
  forward) install_forward ;;
  all)
    install_control "$CP_LOG_DIR"
    install_forward
    ;;
  *)
    echo "Usage: $0 {control|forward|all} [control_log_dir]"
    exit 1
    ;;
esac

logrotate -d "/etc/logrotate.d/gfc-control-plane" 2>/dev/null | head -5 || true
echo "Done. Query logs: sudo bash $SCRIPT_DIR/gfc-logs.sh --help"
