#!/usr/bin/env bash
# GFC client box installer (Ubuntu 22.04+, x86_64 / aarch64)
# Invoked by install.sh or offline tar ./install.sh
_self="${BASH_SOURCE[0]:-$0}"
python3 - "$_self" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
t = p.read_bytes().decode("utf-8", errors="replace")
f = t.replace("\r\n", "\n").replace("\r", "\n")
if f != t:
    p.write_text(f, encoding="utf-8", newline="\n")
    sys.exit(1)
sys.exit(0)
PY
if [[ $? -eq 1 ]]; then exec bash "$_self" "$@"; fi
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLIENT_ROOT="${CLIENT_ROOT:-$(cd "$_SCRIPT_DIR/.." && pwd)}"
PKG_ROOT="${PKG_ROOT:-$CLIENT_ROOT}"
GFC_ROOT="${GFC_ROOT:-/opt/gfc-client}"
POLL_SECONDS="${POLL_SECONDS:-10}"
GFC_PROXY_MODE="${GFC_PROXY_MODE:-gateway}"
GFC_LAN_IFACE="${GFC_LAN_IFACE:-}"
GFC_WAN_IFACE="${GFC_WAN_IFACE:-}"
DEVICE_NAME="${DEVICE_NAME:-$(hostname -s)}"
ACTIVATION_FILE="${ACTIVATION_FILE:-/etc/gfc-client/activation.b32}"
SERVER_URL="${SERVER_URL:-}"
SINGBOX_VERSION="${SINGBOX_VERSION:-1.13.4}"
MOSDNS_VERSION="${MOSDNS_VERSION:-5.3.3}"
REVERSE_SSH_PORT="${REVERSE_SSH_PORT:-}"

if [[ -f /etc/gfc-client/gfc.env ]]; then
  set -a
  # shellcheck disable=SC1091
  source /etc/gfc-client/gfc.env
  set +a
fi

if [[ ! -f "$CLIENT_ROOT/client_agent/__init__.py" ]]; then
  echo "ERROR: missing $CLIENT_ROOT/client_agent (client-agent source tree)"
  exit 1
fi

echo "==> GFC Client Installer (Ubuntu 22.04+)"
echo "    Client source: $CLIENT_ROOT"
echo "    Install root: $GFC_ROOT"
echo "    Proxy mode: $GFC_PROXY_MODE"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash $0"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq python3 python3-venv python3-pip curl rsync nftables iproute2 \
  systemd ca-certificates iputils-ping unzip

mkdir -p "$GFC_ROOT" /etc/gfc-client /var/log/gfc-client /var/lib/gfc-client \
  "$GFC_ROOT/client-agent/state/dataplane" /etc/gfc-client/mosdns

echo "==> IPv4 forwarding + TCP BBR"
cat >/etc/sysctl.d/99-gfc-client.conf <<'EOF'
net.ipv4.ip_forward = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
echo tcp_bbr >/etc/modules-load.d/gfc-client-bbr.conf
modprobe tcp_bbr 2>/dev/null || true
sysctl -p /etc/sysctl.d/99-gfc-client.conf >/dev/null 2>&1 || true

ARCH=$(uname -m)
case "$ARCH" in
  x86_64) SB_ARCH=amd64; MOS_ARCH=amd64 ;;
  aarch64) SB_ARCH=arm64; MOS_ARCH=arm64 ;;
  *) echo "Unsupported arch: $ARCH"; exit 1 ;;
esac

install_sing_box() {
  if [[ -x "$PKG_ROOT/bin/sing-box" ]]; then
    install -m 755 "$PKG_ROOT/bin/sing-box" /usr/local/bin/sing-box
    echo "    sing-box from offline bin/"
    return 0
  fi
  local tmp url
  tmp=$(mktemp -d)
  url="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-${SB_ARCH}.tar.gz"
  echo "    Download sing-box: $url"
  curl -fsSL "$url" -o "$tmp/sb.tgz"
  tar -xzf "$tmp/sb.tgz" -C "$tmp"
  install -m 755 "$(find "$tmp" -name sing-box -type f | head -1)" /usr/local/bin/sing-box
  rm -rf "$tmp"
}

install_mosdns() {
  if [[ -x "$PKG_ROOT/bin/mosdns" ]]; then
    install -m 755 "$PKG_ROOT/bin/mosdns" /usr/local/bin/mosdns
    echo "    mosdns from offline bin/"
    return 0
  fi
  local tmp url zip
  tmp=$(mktemp -d)
  url="https://github.com/IrineSistiana/mosdns/releases/download/v${MOSDNS_VERSION}/mosdns-linux-${MOS_ARCH}.zip"
  echo "    Download mosdns: $url"
  curl -fsSL "$url" -o "$tmp/mosdns.zip"
  unzip -q "$tmp/mosdns.zip" -d "$tmp"
  install -m 755 "$(find "$tmp" -name mosdns -type f | head -1)" /usr/local/bin/mosdns
  rm -rf "$tmp"
}

echo "==> Install sing-box + mosdns"
install_sing_box
install_mosdns

echo "==> Copy client-agent"
rsync -a --delete "$CLIENT_ROOT/" "$GFC_ROOT/client-agent/" \
  --exclude deploy --exclude dist --exclude .venv --exclude state --exclude docs
python3 -m venv "$GFC_ROOT/client-agent/.venv"
"$GFC_ROOT/client-agent/.venv/bin/pip" install -q -U pip
"$GFC_ROOT/client-agent/.venv/bin/pip" install -q -r "$GFC_ROOT/client-agent/requirements.txt"

if [[ -f "$_SCRIPT_DIR/gfc-client-agent-start.sh" ]]; then
  AGENT_START="$_SCRIPT_DIR/gfc-client-agent-start.sh"
  WEB_START="$_SCRIPT_DIR/gfc-client-web-start.sh"
elif [[ -f "$CLIENT_ROOT/deploy/gfc-client-agent-start.sh" ]]; then
  AGENT_START="$CLIENT_ROOT/deploy/gfc-client-agent-start.sh"
  WEB_START="$CLIENT_ROOT/deploy/gfc-client-web-start.sh"
else
  echo "ERROR: start scripts missing"
  exit 1
fi

install -m 755 "$AGENT_START" /usr/local/bin/gfc-client-agent-start
install -m 755 "$WEB_START" /usr/local/bin/gfc-client-web-start

cat >/etc/gfc-client/gfc.env <<EOF
GFC_ROOT=${GFC_ROOT}
GFC_ETC=/etc/gfc-client
SERVER_URL=${SERVER_URL}
DEVICE_NAME=${DEVICE_NAME}
GFC_PROXY_MODE=${GFC_PROXY_MODE}
GFC_LAN_IFACE=${GFC_LAN_IFACE}
GFC_WAN_IFACE=${GFC_WAN_IFACE}
ACTIVATION_FILE=${ACTIVATION_FILE}
STATE_FILE=${GFC_ROOT}/client-agent/state/client_state.json
CONFIG_DIR=${GFC_ROOT}/client-agent/state/dataplane
POLL_SECONDS=${POLL_SECONDS}
REVERSE_SSH_PORT=${REVERSE_SSH_PORT}
GFC_CLIENT_WEB_PORT=8787
GFC_STATUS_FILE=/var/lib/gfc-client/status.json
EOF
chmod 600 /etc/gfc-client/gfc.env

if [[ ! -f "$ACTIVATION_FILE" ]]; then
  echo "    WARN: $ACTIVATION_FILE not found — flash line code before agent can activate"
  touch "$ACTIVATION_FILE"
  chmod 600 "$ACTIVATION_FILE"
fi

cat >/etc/systemd/system/gfc-client-agent.service <<EOF
[Unit]
Description=GFC Client Box Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/gfc-client/gfc.env
WorkingDirectory=${GFC_ROOT}/client-agent
ExecStart=/usr/local/bin/gfc-client-agent-start
Restart=always
RestartSec=5
StandardOutput=append:/var/log/gfc-client/gfc-client-agent.log
StandardError=append:/var/log/gfc-client/gfc-client-agent.log

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/gfc-client-sing-box.service <<EOF
[Unit]
Description=GFC Client sing-box
After=network.target gfc-mosdns.service

[Service]
Type=simple
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStart=/usr/local/bin/sing-box run -c /etc/gfc-client/sing-box.json
Restart=on-failure
RestartSec=3
StandardOutput=append:/var/log/gfc-client/sing-box.log
StandardError=append:/var/log/gfc-client/sing-box.log

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/gfc-mosdns.service <<EOF
[Unit]
Description=GFC Client mosdns
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/mosdns start -c /etc/gfc-client/mosdns.yaml
Restart=on-failure
RestartSec=3
StandardOutput=append:/var/log/gfc-client/mosdns.log
StandardError=append:/var/log/gfc-client/mosdns.log

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/gfc-client-web.service <<EOF
[Unit]
Description=GFC Client local Web UI
After=gfc-client-agent.service

[Service]
Type=simple
EnvironmentFile=/etc/gfc-client/gfc.env
ExecStart=/usr/local/bin/gfc-client-web-start
Restart=on-failure
RestartSec=3
StandardOutput=append:/var/log/gfc-client/gfc-client-web.log
StandardError=append:/var/log/gfc-client/gfc-client-web.log

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable gfc-client-agent gfc-mosdns gfc-client-web
if command -v sing-box >/dev/null 2>&1; then
  systemctl enable gfc-client-sing-box
else
  systemctl disable gfc-client-sing-box 2>/dev/null || true
fi

systemctl restart gfc-mosdns || true
systemctl restart gfc-client-agent
systemctl restart gfc-client-web || true

echo ""
echo "==> Client install complete"
echo "    Config: /etc/gfc-client/gfc.env"
echo "    Line code: $ACTIVATION_FILE"
echo "    Local Web: http://$(hostname -I | awk '{print $1}'):8787"
echo "    Logs: tail -f /var/log/gfc-client/gfc-client-agent.log"
