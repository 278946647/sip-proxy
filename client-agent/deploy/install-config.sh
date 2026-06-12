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

gfc_client_detect_wan_lan() {
  local ifaces wan lan rest
  mapfile -t ifaces < <(ls /sys/class/net 2>/dev/null | while read -r n; do
    [[ "$n" == "lo" ]] && continue
    [[ -e "/sys/class/net/$n/device" ]] || continue
    echo "$n"
  done | sort -V)
  wan="${ifaces[0]:-}"
  lan=""
  for n in "${ifaces[@]:1}"; do lan="$n"; break; done
  GFC_WAN_IFACE="${GFC_WAN_IFACE:-$wan}"
  GFC_LAN_IFACE="${GFC_LAN_IFACE:-$lan}"
  export GFC_WAN_IFACE GFC_LAN_IFACE
}

gfc_client_collect_install_config_interactive() {
  local default_host port host_fb mode
  echo ""
  echo "==> 客户端盒子安装（OpenWrt 模式：首网卡 WAN DHCP，其余 LAN 192.168.68.1/24）"
  echo "    安装完成后通过 http://192.168.68.1:81 刷入线路码，无需提前配置控制平台"
  echo ""

  gfc_client_detect_wan_lan
  gfc_client_list_ifaces
  echo "    自动分配: WAN=${GFC_WAN_IFACE:-?} LAN=${GFC_LAN_IFACE:-?}"
  echo ""

  gfc_client_prompt_default mode "代理模式（默认 gateway）" "gateway"
  gfc_client_prompt_default DEVICE_NAME "设备名称" "$(hostname -s)"
  port="8080"
  default_host=""
  host_fb=""

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
  ACTIVATION_FILE="${ACTIVATION_FILE:-/etc/gfc-client/activation.b32}"
  GFC_ROOT="${GFC_ROOT:-/opt/gfc-client}"
  POLL_SECONDS="${POLL_SECONDS:-10}"

  export API_PORT CONTROL_PLANE_HOST CONTROL_PLANE_HOST_FALLBACK
  export SERVER_URL SERVER_URL_FALLBACK DEVICE_NAME GFC_PROXY_MODE GFC_LAN_IFACE
  export ACTIVATION_FILE GFC_ROOT POLL_SECONDS
}

gfc_client_validate_install_config() {
  gfc_client_detect_wan_lan
  if [[ "${GFC_PROXY_MODE:-gateway}" == "transparent" && -z "${GFC_LAN_IFACE:-}" ]]; then
    echo "ERROR: transparent 模式须设置 GFC_LAN_IFACE"
    return 1
  fi
  if [[ -z "${GFC_WAN_IFACE:-}" ]]; then
    echo "WARN: 未检测到物理网卡，安装后请检查网络"
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
  echo "    设备名称:     ${DEVICE_NAME:-$(hostname -s)}"
  echo "    代理模式:     ${GFC_PROXY_MODE:-gateway}"
  echo "    WAN 网卡:     ${GFC_WAN_IFACE:-（自动）}"
  echo "    LAN 网卡:     ${GFC_LAN_IFACE:-（自动）}"
  echo "    刷码地址:     http://192.168.68.1:81/"
  echo "    管理后台:     http://192.168.68.1/"
  echo ""
}
