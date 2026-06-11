#!/usr/bin/env bash
# Forward node package install (usually invoked by deploy/node/install.sh)
# Direct use: sudo bash install-ubuntu.sh  (set SERVER_URL etc. or run install.sh instead)
_self="${BASH_SOURCE[0]:-$0}"
python3 - "$_self" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
t = p.read_bytes().decode("utf-8", errors="replace")
f = t.replace("\r\n", "\n").replace("\r", "\n")
if p.suffix == ".sh":
    f = f.replace("pipefail" + "STATE=", "pipefail\nSTATE=")
if f != t:
    p.write_text(f, encoding="utf-8", newline="\n")
    sys.exit(1)
sys.exit(0)
PY
if [[ $? -eq 1 ]]; then exec bash "$_self" "$@"; fi
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GFC_ROOT="${GFC_ROOT:-/opt/gfc-node}"
REPO_SRC="${REPO_SRC:-$(cd "$_SCRIPT_DIR/../.." && pwd)}"
SERVER_URL="${SERVER_URL:-http://127.0.0.1:8080}"
BOOTSTRAP_TOKEN="${BOOTSTRAP_TOKEN:-demo-bootstrap}"
NODE_NAME="${NODE_NAME:-$(hostname -s)}"
REGION="${REGION:-ap-southeast-1}"
GFC_TPROXY_IFACE="${GFC_TPROXY_IFACE:-}"
POLL_SECONDS="${POLL_SECONDS:-10}"

# Allow install.sh to pre-write /etc/gfc-node/gfc.env; load if env not exported.
if [[ -f /etc/gfc-node/gfc.env && -z "${SERVER_URL_SET:-}" ]]; then
  if [[ "$SERVER_URL" == "http://127.0.0.1:8080" ]]; then
    set -a
    # shellcheck disable=SC1091
    source /etc/gfc-node/gfc.env
    set +a
  fi
fi

if [[ ! -d "$REPO_SRC/node-agent" ]]; then
  echo "ERROR: missing $REPO_SRC/node-agent — copy full repo or set REPO_SRC"
  exit 1
fi

echo "==> GFC Forward Node Installer (Ubuntu 20.04+)"
echo "    Install root: $GFC_ROOT"
echo "    Control plane: $SERVER_URL"
echo "    TPROXY iface: ${GFC_TPROXY_IFACE:-（未设置）}"

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo bash $0"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq python3 python3-venv python3-pip curl rsync nftables openvpn \
  iproute2 systemd ca-certificates logrotate

mkdir -p "$GFC_ROOT" /etc/gfc-node /var/log/gfc-node \
  "$GFC_ROOT/node-agent/state/dataplane"

echo "==> Enable IPv4 forwarding + TCP BBR"
cat >/etc/sysctl.d/99-gfc-forward.conf <<'EOF'
net.ipv4.ip_forward = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
echo tcp_bbr >/etc/modules-load.d/gfc-bbr.conf
modprobe tcp_bbr 2>/dev/null || true
sysctl -p /etc/sysctl.d/99-gfc-forward.conf >/dev/null 2>&1 || true
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
  sysctl -w net.core.default_qdisc=fq net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
  echo "    BBR: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo off)"
else
  echo "    WARN: kernel has no BBR module; forwarding still enabled"
fi

echo "==> Copy node-agent"
rsync -a --delete "${REPO_SRC}/node-agent/" "$GFC_ROOT/node-agent/" \
  --exclude .venv --exclude state

python3 -m venv "$GFC_ROOT/node-agent/.venv"
"$GFC_ROOT/node-agent/.venv/bin/pip" install -q -U pip
"$GFC_ROOT/node-agent/.venv/bin/pip" install -q -r "$GFC_ROOT/node-agent/requirements.txt"

echo "==> Install sing-box (pinned release, override with SINGBOX_VERSION=latest)"
ARCH=$(uname -m)
case "$ARCH" in
  x86_64) SB_ARCH=amd64 ;;
  aarch64) SB_ARCH=arm64 ;;
  *) echo "Unsupported arch $ARCH"; exit 1 ;;
esac
SINGBOX_VERSION="${SINGBOX_VERSION:-1.13.4}"
install_sing_box() {
  local tmp asset url
  tmp=$(mktemp -d)
  if [[ "$SINGBOX_VERSION" == "latest" ]]; then
    asset=$(python3 - <<'PY' "$SB_ARCH"
import json, sys, urllib.request
arch = sys.argv[1]
req = urllib.request.Request(
    "https://api.github.com/repos/SagerNet/sing-box/releases/latest",
    headers={"Accept": "application/vnd.github+json", "User-Agent": "gfc-installer"},
)
with urllib.request.urlopen(req, timeout=60) as r:
    data = json.load(r)
tag = data["tag_name"]
ver = tag.lstrip("v")
name = f"sing-box-{ver}-linux-{arch}.tar.gz"
for a in data.get("assets", []):
    if a.get("name") == name:
        print(a["browser_download_url"])
        break
else:
    raise SystemExit(f"asset not found: {name} for {tag}")
PY
) || return 1
    url="$asset"
  else
    url="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-${SB_ARCH}.tar.gz"
  fi
  echo "    Download: $url"
  curl -fsSL "$url" -o "$tmp/sb.tgz" || return 1
  tar -xzf "$tmp/sb.tgz" -C "$tmp"
  install -m 755 "$tmp"/sing-box*/sing-box /usr/local/bin/sing-box 2>/dev/null || \
    install -m 755 "$(find "$tmp" -name sing-box -type f | head -1)" /usr/local/bin/sing-box
  rm -rf "$tmp"
  sing-box version >/dev/null 2>&1
}
if install_sing_box; then
  echo "    OK sing-box $(sing-box version 2>/dev/null | head -1 || true) -> $(command -v sing-box)"
else
  echo "    WARN sing-box install failed (404 or network). Install manually; gfc-sing-box stays disabled until binary exists."
fi

cat >/etc/gfc-node/gfc.env <<EOF
SERVER_URL=${SERVER_URL}
BOOTSTRAP_TOKEN=${BOOTSTRAP_TOKEN}
NODE_NAME=${NODE_NAME}
REGION=${REGION}
GFC_ROOT=${GFC_ROOT}
GFC_ETC=/etc/gfc-node
GFC_TPROXY_IFACE=${GFC_TPROXY_IFACE}
GFC_SNAT_IFACE=${GFC_SNAT_IFACE:-auto}
STATE_FILE=${GFC_ROOT}/node-agent/state/node_state.json
CONFIG_DIR=${GFC_ROOT}/node-agent/state/dataplane
POLL_SECONDS=${POLL_SECONDS}
EOF
chmod 600 /etc/gfc-node/gfc.env

install -m 755 "$_SCRIPT_DIR/gfc-node-agent-start.sh" /usr/local/bin/gfc-node-agent-start

cat >/etc/systemd/system/gfc-node-agent.service <<EOF
[Unit]
Description=GFC Forward Node Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/gfc-node/gfc.env
WorkingDirectory=${GFC_ROOT}/node-agent
ExecStart=/usr/local/bin/gfc-node-agent-start
Restart=always
RestartSec=5
StandardOutput=append:/var/log/gfc-node/gfc-node-agent.log
StandardError=append:/var/log/gfc-node/gfc-node-agent.log

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/gfc-sing-box.service <<EOF
[Unit]
Description=GFC sing-box transparent proxy
After=network.target gfc-node-agent.service

[Service]
Type=simple
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStart=/usr/local/bin/sing-box run -c /etc/gfc-node/sing-box.json
Restart=on-failure
RestartSec=3
StandardOutput=append:/var/log/gfc-node/sing-box.log
StandardError=append:/var/log/gfc-node/sing-box.log

[Install]
WantedBy=multi-user.target
EOF

mkdir -p /etc/systemd/system/openvpn@gfc-backbone.service.d
cat >/etc/systemd/system/openvpn@gfc-backbone.service.d/gfc-log.conf <<'EOF'
[Service]
StandardOutput=append:/var/log/gfc-node/openvpn-gfc-backbone.log
StandardError=append:/var/log/gfc-node/openvpn-gfc-backbone.log
EOF

_LOGROTATE="$REPO_SRC/deploy/scripts/install-logrotate.sh"
if [[ -f "$_LOGROTATE" ]]; then
  bash "$_LOGROTATE" forward
  install -m 755 "$REPO_SRC/deploy/scripts/gfc-logs.sh" /usr/local/bin/gfc-logs 2>/dev/null || true
fi

if [[ -n "${GFC_TPROXY_IFACE:-}" ]]; then
  echo "==> TPROXY policy routing (fwmark 0x1 -> table 100)"
  ip rule add fwmark 0x1 lookup 100 2>/dev/null || true
  ip route replace local 0.0.0.0/0 dev lo table 100 2>/dev/null || true
fi

SNAT_IF="${GFC_SNAT_IFACE:-auto}"
if [[ "$SNAT_IF" == "auto" ]]; then
  SNAT_IF=$(ip -4 route show default 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | head -1)
fi
if [[ -n "$SNAT_IF" && "$SNAT_IF" != "0" && "$SNAT_IF" != "off" ]]; then
  echo "==> Egress SNAT on $SNAT_IF (Windows NCSI / default route)"
  nft delete table ip gfc-nat 2>/dev/null || true
  nft -f - <<EOF
table ip gfc-nat {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    oifname "${SNAT_IF}" masquerade
  }
}
EOF
fi

systemctl daemon-reload
systemctl enable gfc-node-agent
if command -v sing-box >/dev/null 2>&1; then
  systemctl enable gfc-sing-box
else
  systemctl disable gfc-sing-box 2>/dev/null || true
fi
systemctl restart gfc-node-agent
sleep 3
if [[ -f "${GFC_ROOT}/node-agent/state/node_state.json" ]]; then
  echo "    OK node activated (state file present)"
else
  echo "    WARN no state file yet — check: gfc-logs agent -n 40  (or journalctl -u gfc-node-agent -n 40)"
  echo "         curl -fsS ${SERVER_URL}/healthz"
fi

echo ""
echo "==> Installed."
echo "    配置: /etc/gfc-node/gfc.env  (改后 systemctl restart gfc-node-agent)"
echo "    重配: sudo bash $_SCRIPT_DIR/reconfigure-node.sh"
echo "    日志: gfc-logs agent -f   (文件 /var/log/gfc-node/, 保留约 1 天)"
echo ""
echo "OpenVPN: 在控制台切换连接模式并下发证书；tproxyIface 自动用 tun0，无需改物理网卡名。"
