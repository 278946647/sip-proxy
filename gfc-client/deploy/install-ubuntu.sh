#!/usr/bin/env bash
# GFC Client — Ubuntu 22.04 full install (Go + Vue3)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GFC_ROOT="${GFC_ROOT:-/opt/gfc-client}"
SINGBOX_VERSION="${SINGBOX_VERSION:-1.13.4}"
# easymosdns needs mosdns-x pipeline; default pmkol/mosdns-x, fallback IrineSistiana/mosdns
MOSDNS_VERSION="${MOSDNS_VERSION:-}"

if [[ "${EUID:-0}" -ne 0 ]]; then
  echo "Run as root: sudo bash deploy/install-ubuntu.sh"
  exit 1
fi

echo "==> Packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl rsync nftables iproute2 dnsmasq netplan.io \
  git ca-certificates unzip xz-utils openssh-client autossh

mkdir -p "$GFC_ROOT" /etc/gfc-client /var/log/gfc-client /var/lib/gfc-client/state \
  /var/lib/gfc-client/rules /var/lib/gfc-client/dns-lists /var/lib/gfc-client/backups \
  /etc/gfc-client/mosdns /etc/gfc-client/policy

echo "==> Sysctl BBR"
cat >/etc/sysctl.d/99-gfc-client.conf <<'EOF'
net.ipv4.ip_forward = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
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
    return
  fi
  tmp=$(mktemp -d)
  url="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-${SB_ARCH}.tar.gz"
  echo "    Download sing-box $url"
  curl -fsSL "$url" -o "$tmp/sb.tgz"
  tar -xzf "$tmp/sb.tgz" -C "$tmp"
  install -m 755 "$(find "$tmp" -name sing-box -type f | head -1)" /usr/local/bin/sing-box
  rm -rf "$tmp"
}

install_mosdns() {
  if [[ -x "$PKG_ROOT/bin/mosdns" ]]; then
    install -m 755 "$PKG_ROOT/bin/mosdns" /usr/local/bin/mosdns
    echo "    mosdns from offline bin/"
    return
  fi
  # shellcheck source=install-mosdns-bin.sh
  source "$SCRIPT_DIR/install-mosdns-bin.sh"
  install_mosdns_bin /usr/local/bin/mosdns
}

echo "==> sing-box + mosdns"
install_sing_box
install_mosdns

echo "==> Go toolchain"
# shellcheck source=install-go.sh
source "$SCRIPT_DIR/install-go.sh"
ensure_go

echo "==> Sync source -> $GFC_ROOT"
rsync -a --delete \
  --exclude '.git' --exclude 'web/node_modules' --exclude 'web/dist' \
  "$PKG_ROOT/" "$GFC_ROOT/"

echo "==> Build Go + Web"
bash "$GFC_ROOT/deploy/build.sh"

install -m 755 "$GFC_ROOT/bin/gfc-api" /usr/local/bin/gfc-api
install -m 755 "$GFC_ROOT/bin/gfc-agent" /usr/local/bin/gfc-agent
install -m 755 "$GFC_ROOT/bin/gfc-bootstrap" /usr/local/bin/gfc-bootstrap

if [[ -d "$GFC_ROOT/web-static" ]]; then
  rm -rf "$GFC_ROOT/web"
  cp -a "$GFC_ROOT/web-static" "$GFC_ROOT/web"
fi

echo "==> Bundled rules"
cp -a "$GFC_ROOT/share/rules/." /var/lib/gfc-client/rules/ 2>/dev/null || true

if [[ ! -f /etc/gfc-client/gfc.env ]]; then
  cat >/etc/gfc-client/gfc.env <<EOF
GFC_ROOT=$GFC_ROOT
GFC_ETC=/etc/gfc-client
GFC_LIB=/var/lib/gfc-client
DEVICE_NAME=gfc-box-001
GFC_PROXY_MODE=gateway
POLL_SECONDS=10
GFC_CLIENT_WEB_PORT=80
GFC_CLIENT_FLASH_PORT=81
EOF
  chmod 600 /etc/gfc-client/gfc.env
fi

echo "==> systemd-resolved"
if systemctl is-enabled systemd-resolved &>/dev/null; then
  systemctl disable --now systemd-resolved || true
fi

echo "==> systemd units"
# retire legacy unit names
for legacy in gfc-client-agent gfc-client-api gfc-client-sing-box; do
  systemctl disable --now "$legacy" 2>/dev/null || true
  rm -f "/etc/systemd/system/${legacy}.service"
done

cat >/etc/systemd/system/gfc-network.service <<EOF
[Unit]
Description=GFC Client Network Bootstrap
After=network-online.target systemd-networkd.service
Wants=network-online.target
Before=dnsmasq.service gfc-mosdns.service

[Service]
Type=oneshot
RemainAfterExit=yes
EnvironmentFile=/etc/gfc-client/gfc.env
ExecStart=/bin/bash ${GFC_ROOT}/deploy/gfc-network.sh start

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/gfc-mosdns.service <<'EOF'
[Unit]
Description=GFC MosDNS (sole DNS :53)
After=gfc-network.service
Requires=gfc-network.service
Before=gfc-sing-box.service

[Service]
Type=simple
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
WorkingDirectory=/etc/gfc-client/mosdns/easymosdns
ExecStart=/usr/local/bin/mosdns start -c /etc/gfc-client/mosdns/easymosdns/config.yaml
Restart=on-failure
RestartSec=3
StandardOutput=append:/var/log/gfc-client/mosdns.log
StandardError=append:/var/log/gfc-client/mosdns.log

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/gfc-sing-box.service <<EOF
[Unit]
Description=GFC Sing-box TUN (gfctun)
After=gfc-mosdns.service
Requires=gfc-mosdns.service
Before=gfc-agent.service

[Service]
Type=simple
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStart=/usr/local/bin/sing-box run -c /etc/gfc-client/sing-box.json
ExecStopPost=/bin/bash ${GFC_ROOT}/deploy/singbox-nft-cleanup.sh
Restart=on-failure
RestartSec=3
StandardOutput=append:/var/log/gfc-client/sing-box.log
StandardError=append:/var/log/gfc-client/sing-box.log

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/gfc-agent.service <<EOF
[Unit]
Description=GFC Client Agent
After=gfc-sing-box.service network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/gfc-client/gfc.env
ExecStart=/usr/local/bin/gfc-agent
Restart=always
RestartSec=3
StandardOutput=append:/var/log/gfc-client/gfc-agent.log
StandardError=append:/var/log/gfc-client/gfc-agent.log

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/gfc-web.service <<EOF
[Unit]
Description=GFC Client Web UI
After=gfc-agent.service

[Service]
Type=simple
EnvironmentFile=/etc/gfc-client/gfc.env
Environment=GFC_WEB_MODE=both
ExecStart=/usr/local/bin/gfc-api
Restart=always
RestartSec=3
StandardOutput=append:/var/log/gfc-client/gfc-api.log
StandardError=append:/var/log/gfc-client/gfc-api.log

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable gfc-network gfc-mosdns gfc-sing-box gfc-agent gfc-web

echo "==> logrotate"
install -m 644 "$GFC_ROOT/deploy/gfc-client-logrotate" /etc/logrotate.d/gfc-client

echo "==> Network bootstrap"
chmod +x "$GFC_ROOT/deploy"/*.sh
systemctl start gfc-network || bash "$GFC_ROOT/deploy/gfc-network.sh" start || echo "WARN: gfc-network skipped"

echo "==> Bootstrap dataplane (idle)"
chmod +x "$GFC_ROOT/deploy/bootstrap-idle.sh"
bash "$GFC_ROOT/deploy/bootstrap-idle.sh"
systemctl restart gfc-agent gfc-web gfc-mosdns gfc-sing-box || true

echo ""
echo "Install complete."
echo "  Web admin : http://$(hostname -I | awk '{print $1}'):80"
echo "  Flash     : http://$(hostname -I | awk '{print $1}'):81"
echo "  Logs      : /var/log/gfc-client/"
