# Shared install parameter helpers (source only).
# shellcheck shell=bash

gfc_install_script_dir() {
  cd "$(dirname "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")" && pwd
}

gfc_list_ifaces() {
  echo "可用网卡:"
  ip -br link show 2>/dev/null | while read -r name _ rest; do
    [[ "$name" == "lo" ]] && continue
    state=$(echo "$rest" | awk '{print $1}')
    printf '    %-16s %s\n' "$name" "$state"
  done
}

gfc_iface_exists() {
  local iface=$1
  [[ -n "$iface" ]] || return 0
  ip link show "$iface" &>/dev/null
}

# Build http(s)://host:port from bare IP, domain, host:port, or full URL.
gfc_normalize_control_plane_url() {
  local input=${1:-}
  local port=${2:-8080}
  local scheme=${3:-http}
  input=$(echo "$input" | tr -d '[:space:]')
  [[ -n "$input" ]] || return 1
  if [[ "$input" == *"://"* ]]; then
    echo "$input"
    return 0
  fi
  if [[ "$input" == \[*\]* ]]; then
    if [[ "$input" == *:* ]]; then
      echo "${scheme}://${input}"
    else
      echo "${scheme}://${input}:${port}"
    fi
    return 0
  fi
  if [[ "$input" == *:* ]]; then
    echo "${scheme}://${input}"
    return 0
  fi
  echo "${scheme}://${input}:${port}"
}

gfc_build_server_url() {
  if [[ -n "${SERVER_URL:-}" ]]; then
    SERVER_URL=$(gfc_normalize_control_plane_url "$SERVER_URL" "${API_PORT:-8080}" || echo "$SERVER_URL")
    export SERVER_URL
    return 0
  fi
  local host=${CONTROL_PLANE_HOST:-${CONTROL_PLANE_IP:-}}
  local port=${API_PORT:-8080}
  [[ -n "$host" ]] || return 1
  SERVER_URL=$(gfc_normalize_control_plane_url "$host" "$port")
  export SERVER_URL
}

gfc_build_server_url_fallback() {
  if [[ -n "${SERVER_URL_FALLBACK:-}" ]]; then
    SERVER_URL_FALLBACK=$(gfc_normalize_control_plane_url "$SERVER_URL_FALLBACK" "${API_PORT:-8080}" || echo "$SERVER_URL_FALLBACK")
    export SERVER_URL_FALLBACK
    return 0
  fi
  local host=${CONTROL_PLANE_HOST_FALLBACK:-${CONTROL_PLANE_IP_FALLBACK:-}}
  local port=${API_PORT:-8080}
  [[ -n "$host" ]] || return 0
  SERVER_URL_FALLBACK=$(gfc_normalize_control_plane_url "$host" "$port")
  export SERVER_URL_FALLBACK
}

gfc_load_install_env_file() {
  local file=$1
  [[ -f "$file" ]] || return 1
  # shellcheck disable=SC1090
  set -a
  source "$file"
  set +a
  gfc_build_server_url || true
  gfc_build_server_url_fallback || true
  export SERVER_URL="${SERVER_URL:-}"
  export SERVER_URL_FALLBACK="${SERVER_URL_FALLBACK:-}"
  export BOOTSTRAP_TOKEN="${BOOTSTRAP_TOKEN:-demo-bootstrap}"
  export NODE_NAME="${NODE_NAME:-$(hostname -s)}"
  export REGION="${REGION:-ap-southeast-1}"
  export GFC_TPROXY_IFACE="${GFC_TPROXY_IFACE:-}"
  export GFC_ROOT="${GFC_ROOT:-/opt/gfc-node}"
  export REPO_SRC="${REPO_SRC:-}"
  export SINGBOX_VERSION="${SINGBOX_VERSION:-1.13.4}"
  export POLL_SECONDS="${POLL_SECONDS:-10}"
  export GFC_SNAT_IFACE="${GFC_SNAT_IFACE:-auto}"
  return 0
}

gfc_prompt_default() {
  local var_name=$1
  local prompt=$2
  local default=$3
  local input
  read -r -p "$prompt [$default]: " input
  if [[ -z "$input" ]]; then
    printf -v "$var_name" '%s' "$default"
  else
    printf -v "$var_name" '%s' "$input"
  fi
}

gfc_collect_install_config_interactive() {
  echo ""
  echo "==> 转发节点安装参数（直接回车采用默认值）"
  echo "    控制平台地址支持 IP 或域名，例如 192.168.1.10 / api.example.com"
  echo "    也可填写完整 URL，例如 https://api.example.com:8080"
  echo "    说明: 以太网模式用「TPROXY 入向网卡」；日后改 OpenVPN 时控制台会下发 tun0，"
  echo "          自动覆盖网卡设置，开局填的物理网卡不会影响 VPN 模式切换。"
  echo ""

  local host port host_fb token name region iface
  gfc_prompt_default host "控制平台地址（IP 或域名）" "127.0.0.1"
  gfc_prompt_default port "控制平台 API 端口" "8080"
  read -r -p "备用控制平台地址（IP 或域名，可留空）: " host_fb
  echo "    Bootstrap Token 默认 demo-bootstrap（控制平台未自定义时直接回车）"
  gfc_prompt_default token "Bootstrap Token" "demo-bootstrap"
  gfc_prompt_default name "转发节点名称 NODE_NAME" "$(hostname -s)"
  gfc_prompt_default region "区域 REGION" "ap-southeast-1"

  echo ""
  gfc_list_ifaces
  echo ""
  gfc_prompt_default iface "TPROXY 入向网卡 GFC_TPROXY_IFACE（以太网/VyOS 侧，可留空稍后填）" ""

  if [[ -n "$iface" ]] && ! gfc_iface_exists "$iface"; then
    echo "WARN: 网卡 $iface 当前不存在，仍写入配置（插线/改名后生效）"
  fi

  CONTROL_PLANE_HOST=$host
  CONTROL_PLANE_IP=$host
  API_PORT=$port
  SERVER_URL=$(gfc_normalize_control_plane_url "$host" "$port")
  if [[ -n "$host_fb" ]]; then
    CONTROL_PLANE_HOST_FALLBACK=$host_fb
    CONTROL_PLANE_IP_FALLBACK=$host_fb
    SERVER_URL_FALLBACK=$(gfc_normalize_control_plane_url "$host_fb" "$port")
  else
    CONTROL_PLANE_HOST_FALLBACK=
    CONTROL_PLANE_IP_FALLBACK=
    SERVER_URL_FALLBACK=
  fi
  BOOTSTRAP_TOKEN=$token
  NODE_NAME=$name
  REGION=$region
  GFC_TPROXY_IFACE=$iface
  GFC_ROOT="${GFC_ROOT:-/opt/gfc-node}"
  SINGBOX_VERSION="${SINGBOX_VERSION:-1.13.4}"
  POLL_SECONDS="${POLL_SECONDS:-10}"

  export CONTROL_PLANE_HOST CONTROL_PLANE_IP API_PORT SERVER_URL
  export CONTROL_PLANE_HOST_FALLBACK CONTROL_PLANE_IP_FALLBACK SERVER_URL_FALLBACK
  export BOOTSTRAP_TOKEN NODE_NAME REGION
  export GFC_TPROXY_IFACE GFC_ROOT SINGBOX_VERSION POLL_SECONDS
}

gfc_probe_control_plane_url() {
  local url=$1
  local label=$2
  [[ -n "$url" ]] || return 0
  if curl -fsS --connect-timeout 5 "${url%/}/healthz" >/dev/null 2>&1; then
    echo "    OK ${label} ${url} 可达"
    return 0
  fi
  echo "    WARN ${label} ${url} 暂不可达"
  return 1
}

gfc_validate_install_config() {
  gfc_build_server_url || true
  gfc_build_server_url_fallback || true
  local err=0
  if [[ -z "${SERVER_URL:-}" ]]; then
    echo "ERROR: 未设置 SERVER_URL、CONTROL_PLANE_HOST 或 CONTROL_PLANE_IP"
    err=1
  fi
  if [[ -z "${NODE_NAME:-}" ]]; then
    echo "ERROR: 未设置 NODE_NAME"
    err=1
  fi
  if [[ -n "${GFC_TPROXY_IFACE:-}" ]] && ! gfc_iface_exists "$GFC_TPROXY_IFACE"; then
    echo "WARN: 网卡 ${GFC_TPROXY_IFACE} 不存在（已写入配置，请确认名称正确）"
  fi
  if command -v curl &>/dev/null; then
    echo "==> 检查控制平台连通性"
    gfc_probe_control_plane_url "$SERVER_URL" "主地址" || true
    if [[ -n "${SERVER_URL_FALLBACK:-}" ]]; then
      gfc_probe_control_plane_url "$SERVER_URL_FALLBACK" "备用地址" || true
    fi
    if [[ -n "${BOOTSTRAP_TOKEN:-}" ]]; then
      local code probe_url
      for probe_url in "$SERVER_URL" "${SERVER_URL_FALLBACK:-}"; do
        [[ -n "$probe_url" ]] || continue
        code=$(curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 5 \
          -X POST "${probe_url%/}/nodes/bootstrap-check" \
          -H "Content-Type: application/json" \
          -d "{\"bootstrap_token\":\"${BOOTSTRAP_TOKEN}\",\"node_name\":\"install-probe\",\"region\":\"test\"}" \
          2>/dev/null || echo "000")
        case "$code" in
          200) echo "    OK bootstrap token 有效 (${probe_url})"; break ;;
          403) echo "    WARN bootstrap token 被拒绝(403) @ ${probe_url}"; err=1 ;;
          000) ;;
          *) echo "    WARN bootstrap-check @ ${probe_url} HTTP $code" ;;
        esac
      done
    fi
  fi
  return "$err"
}

gfc_write_install_files() {
  local gfc_env=${1:-/etc/gfc-node/gfc.env}
  local install_env=${2:-/etc/gfc-node/install.env}
  local gfc_root=${GFC_ROOT:-/opt/gfc-node}
  local poll=${POLL_SECONDS:-10}

  mkdir -p "$(dirname "$gfc_env")"

  cat >"$install_env" <<EOF
# Generated by GFC forward node installer — re-run: sudo bash deploy/node/reconfigure-node.sh
SERVER_URL=${SERVER_URL}
SERVER_URL_FALLBACK=${SERVER_URL_FALLBACK:-}
CONTROL_PLANE_HOST=${CONTROL_PLANE_HOST:-${CONTROL_PLANE_IP:-}}
CONTROL_PLANE_HOST_FALLBACK=${CONTROL_PLANE_HOST_FALLBACK:-${CONTROL_PLANE_IP_FALLBACK:-}}
CONTROL_PLANE_IP=${CONTROL_PLANE_IP:-}
CONTROL_PLANE_IP_FALLBACK=${CONTROL_PLANE_IP_FALLBACK:-}
API_PORT=${API_PORT:-8080}
BOOTSTRAP_TOKEN=${BOOTSTRAP_TOKEN}
NODE_NAME=${NODE_NAME}
REGION=${REGION}
GFC_TPROXY_IFACE=${GFC_TPROXY_IFACE}
GFC_ROOT=${gfc_root}
SINGBOX_VERSION=${SINGBOX_VERSION:-1.13.4}
POLL_SECONDS=${poll}
EOF
  chmod 600 "$install_env"

  cat >"$gfc_env" <<EOF
# GFC forward node runtime — edit then: sudo systemctl restart gfc-node-agent
SERVER_URL=${SERVER_URL}
SERVER_URL_FALLBACK=${SERVER_URL_FALLBACK:-}
BOOTSTRAP_TOKEN=${BOOTSTRAP_TOKEN}
NODE_NAME=${NODE_NAME}
REGION=${REGION}
GFC_ROOT=${gfc_root}
GFC_ETC=/etc/gfc-node
# 以太网模式 TPROXY 入向网卡；OpenVPN 模式下控制台下发 tproxyIface 优先
GFC_TPROXY_IFACE=${GFC_TPROXY_IFACE}
STATE_FILE=${gfc_root}/node-agent/state/node_state.json
CONFIG_DIR=${gfc_root}/node-agent/state/dataplane
POLL_SECONDS=${poll}
GFC_SNAT_IFACE=${GFC_SNAT_IFACE:-auto}
EOF
  chmod 600 "$gfc_env"
  echo "==> 已写入 $gfc_env"
  echo "==> 已写入 $install_env"
}

gfc_show_install_summary() {
  echo ""
  echo "==> 安装参数摘要"
  echo "    控制平台(主): ${SERVER_URL}"
  if [[ -n "${SERVER_URL_FALLBACK:-}" ]]; then
    echo "    控制平台(备): ${SERVER_URL_FALLBACK}"
  fi
  echo "    节点名称:  ${NODE_NAME}"
  echo "    区域:      ${REGION}"
  echo "    TPROXY网卡: ${GFC_TPROXY_IFACE:-（未设置，以太网模式需在控制台或 gfc.env 中配置）}"
  echo "    安装目录:  ${GFC_ROOT:-/opt/gfc-node}"
  echo ""
}
