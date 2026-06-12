# Client box install parameter helpers (source only).
# shellcheck shell=bash

gfc_client_normalize_url() {
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

gfc_client_prompt_default() {
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

gfc_client_list_ifaces() {
  echo "可用网卡:"
  ip -br link show 2>/dev/null | while read -r name _ rest; do
    [[ "$name" == "lo" ]] && continue
    state=$(echo "$rest" | awk '{print $1}')
    printf '    %-16s %s\n' "$name" "$state"
  done
}

gfc_client_activation_hint() {
  local file=${1:-/etc/gfc-client/activation.b32}
  if [[ ! -f "$file" ]] || [[ ! -s "$file" ]]; then
    echo "    （尚未刷入线路码，安装后执行 flash-line-code.sh）"
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$file" <<'PY' 2>/dev/null || true
import base64, json, sys
raw = open(sys.argv[1], encoding="utf-8").read().strip()
if not raw:
    sys.exit(0)
norm = raw.upper().replace(" ", "").replace("-", "")
pad = (-len(norm)) % 8
data = json.loads(base64.b32decode(norm + "=" * pad))
server = data.get("server") or ""
fb = data.get("serverFallback") or ""
print(f"    线路码内嵌 API: {server or '(无)'}")
if fb:
    print(f"    线路码备用 API: {fb}")
PY
  fi
}

gfc_client_load_install_env_file() {
  local file=$1
  [[ -f "$file" ]] || return 1
  set -a
  # shellcheck disable=SC1090
  source "$file"
  set +a
  if [[ -n "${SERVER_URL:-}" ]]; then
    SERVER_URL=$(gfc_client_normalize_url "$SERVER_URL" "${API_PORT:-8080}" || echo "$SERVER_URL")
  elif [[ -n "${CONTROL_PLANE_HOST:-}" ]]; then
    SERVER_URL=$(gfc_client_normalize_url "$CONTROL_PLANE_HOST" "${API_PORT:-8080}")
  fi
  if [[ -n "${SERVER_URL_FALLBACK:-}" ]]; then
    SERVER_URL_FALLBACK=$(gfc_client_normalize_url "$SERVER_URL_FALLBACK" "${API_PORT:-8080}" || echo "$SERVER_URL_FALLBACK")
  elif [[ -n "${CONTROL_PLANE_HOST_FALLBACK:-}" ]]; then
    SERVER_URL_FALLBACK=$(gfc_client_normalize_url "$CONTROL_PLANE_HOST_FALLBACK" "${API_PORT:-8080}")
  fi
  export SERVER_URL="${SERVER_URL:-}"
  export SERVER_URL_FALLBACK="${SERVER_URL_FALLBACK:-}"
  export DEVICE_NAME="${DEVICE_NAME:-$(hostname -s)}"
  export GFC_PROXY_MODE="${GFC_PROXY_MODE:-gateway}"
  export GFC_LAN_IFACE="${GFC_LAN_IFACE:-}"
  export GFC_WAN_IFACE="${GFC_WAN_IFACE:-}"
  export ACTIVATION_FILE="${ACTIVATION_FILE:-/etc/gfc-client/activation.b32}"
  export GFC_ROOT="${GFC_ROOT:-/opt/gfc-client}"
  export POLL_SECONDS="${POLL_SECONDS:-10}"
  return 0
}

gfc_client_collect_install_config_interactive() {
  local default_host port host_fb mode lan
  echo ""
  echo "==> 客户端盒子安装参数（直接回车采用默认值）"
  echo "    控制平台 API 支持 IP 或域名；若已刷线路码可留空（优先用线路码内嵌地址）"
  gfc_client_activation_hint "${ACTIVATION_FILE:-/etc/gfc-client/activation.b32}"
  echo ""

  gfc_client_prompt_default port "控制平台 API 端口" "8080"
  read -r -p "控制平台地址（IP 或域名，留空=仅用线路码）: " default_host
  read -r -p "备用控制平台地址（IP 或域名，可留空）: " host_fb
  gfc_client_prompt_default mode "代理模式 gateway|bypass|transparent" "gateway"
  echo ""
  gfc_client_list_ifaces
  echo ""
  gfc_client_prompt_default lan "LAN 网卡 GFC_LAN_IFACE（transparent 必填，gateway 可留空）" "eth1"
  gfc_client_prompt_default DEVICE_NAME "设备名称 DEVICE_NAME" "$(hostname -s)"

  API_PORT=$port
  if [[ -n "$default_host" ]]; then
    CONTROL_PLANE_HOST=$default_host
    SERVER_URL=$(gfc_client_normalize_url "$default_host" "$port")
  else
    CONTROL_PLANE_HOST=
    SERVER_URL=
  fi
  if [[ -n "$host_fb" ]]; then
    CONTROL_PLANE_HOST_FALLBACK=$host_fb
    SERVER_URL_FALLBACK=$(gfc_client_normalize_url "$host_fb" "$port")
  else
    CONTROL_PLANE_HOST_FALLBACK=
    SERVER_URL_FALLBACK=
  fi
  GFC_PROXY_MODE=$mode
  GFC_LAN_IFACE=$lan
  ACTIVATION_FILE="${ACTIVATION_FILE:-/etc/gfc-client/activation.b32}"
  GFC_ROOT="${GFC_ROOT:-/opt/gfc-client}"
  POLL_SECONDS="${POLL_SECONDS:-10}"

  export API_PORT CONTROL_PLANE_HOST CONTROL_PLANE_HOST_FALLBACK
  export SERVER_URL SERVER_URL_FALLBACK DEVICE_NAME GFC_PROXY_MODE GFC_LAN_IFACE
  export ACTIVATION_FILE GFC_ROOT POLL_SECONDS
}

gfc_client_validate_install_config() {
  if [[ ! -f "${ACTIVATION_FILE:-/etc/gfc-client/activation.b32}" || ! -s "${ACTIVATION_FILE:-/etc/gfc-client/activation.b32}" ]]; then
    if [[ -z "${SERVER_URL:-}" ]]; then
      echo "WARN: 未刷线路码且未填控制平台地址 — 请先 flash-line-code.sh 或填写 SERVER_URL"
    fi
  fi
  if [[ "${GFC_PROXY_MODE:-gateway}" == "transparent" && -z "${GFC_LAN_IFACE:-}" ]]; then
    echo "ERROR: transparent 模式须设置 GFC_LAN_IFACE"
    return 1
  fi
  if command -v curl &>/dev/null && [[ -n "${SERVER_URL:-}" ]]; then
    echo "==> 检查控制平台 ${SERVER_URL}/healthz"
    if curl -fsS --connect-timeout 5 "${SERVER_URL%/}/healthz" >/dev/null 2>&1; then
      echo "    OK 控制平台可达"
    else
      echo "    WARN 暂不可达（继续安装，请检查网络/DNS）"
    fi
  fi
  return 0
}

gfc_client_write_install_env_file() {
  local file=${1:-/etc/gfc-client/install.env}
  mkdir -p "$(dirname "$file")"
  cat >"$file" <<EOF
# Generated by GFC client installer
SERVER_URL=${SERVER_URL:-}
SERVER_URL_FALLBACK=${SERVER_URL_FALLBACK:-}
CONTROL_PLANE_HOST=${CONTROL_PLANE_HOST:-}
CONTROL_PLANE_HOST_FALLBACK=${CONTROL_PLANE_HOST_FALLBACK:-}
API_PORT=${API_PORT:-8080}
DEVICE_NAME=${DEVICE_NAME:-$(hostname -s)}
GFC_PROXY_MODE=${GFC_PROXY_MODE:-gateway}
GFC_LAN_IFACE=${GFC_LAN_IFACE:-}
GFC_WAN_IFACE=${GFC_WAN_IFACE:-}
ACTIVATION_FILE=${ACTIVATION_FILE:-/etc/gfc-client/activation.b32}
GFC_ROOT=${GFC_ROOT:-/opt/gfc-client}
POLL_SECONDS=${POLL_SECONDS:-10}
EOF
  chmod 600 "$file"
  echo "==> 已写入 $file"
}

gfc_client_show_install_summary() {
  echo ""
  echo "==> 安装参数摘要"
  echo "    控制平台(主): ${SERVER_URL:-（使用线路码内嵌地址）}"
  if [[ -n "${SERVER_URL_FALLBACK:-}" ]]; then
    echo "    控制平台(备): ${SERVER_URL_FALLBACK}"
  fi
  echo "    设备名称:     ${DEVICE_NAME:-$(hostname -s)}"
  echo "    代理模式:     ${GFC_PROXY_MODE:-gateway}"
  echo "    LAN 网卡:     ${GFC_LAN_IFACE:-（未设置）}"
  echo "    线路码文件:   ${ACTIVATION_FILE:-/etc/gfc-client/activation.b32}"
  echo ""
}
