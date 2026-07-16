#!/usr/bin/env bash
# Official GFC control-plane compose wrapper.
# Always removes old containers before "up" to avoid docker-compose 1.29 ContainerConfig bug.
#
# Prefer running via /usr/local/bin/gfc-compose (wrapper sets GFC_ROOT), or:
#   cd /opt/sip-proxy/gfc-platform && ./deploy/control/gfc-compose.sh up -d
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

gfc_compose_resolve_root() {
  local candidate
  if [[ -n "${GFC_ROOT:-}" ]]; then
    candidate=$(cd "$GFC_ROOT" && pwd)
    if [[ -f "$candidate/deploy/control/compose-util.sh" ]]; then
      echo "$candidate"
      return 0
    fi
  fi
  # Running from repo: deploy/control/gfc-compose.sh → gfc-platform root
  candidate=$(cd "$_SCRIPT_DIR/../.." && pwd)
  if [[ -f "$candidate/deploy/control/compose-util.sh" ]]; then
    echo "$candidate"
    return 0
  fi
  for candidate in /opt/sip-proxy/gfc-platform /opt/gfc /var/socks/gfc-platform; do
    if [[ -f "$candidate/deploy/control/compose-util.sh" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  echo "ERROR: 找不到 gfc-platform（compose-util.sh）。请设置 GFC_ROOT=/opt/sip-proxy/gfc-platform" >&2
  return 1
}

ROOT="$(gfc_compose_resolve_root)"
# shellcheck source=deploy/control/compose-util.sh
source "$ROOT/deploy/control/compose-util.sh"

gfc_compose_cmd_up() {
  local detach=0
  local do_build=0
  local services=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d | --detach)
        detach=1
        shift
        ;;
      --build)
        do_build=1
        shift
        ;;
      --force-recreate | --renew-anon-volumes)
        echo "ERROR: $1 会触发 docker-compose 1.29 的 ContainerConfig 错误。" >&2
        echo "请使用: gfc-compose up -d [api] [web]" >&2
        exit 1
        ;;
      --no-deps | --scale | -t | --timeout | --remove-orphans)
        echo "ERROR: gfc-compose up 不支持 $1（内部已处理容器替换）。" >&2
        exit 1
        ;;
      -*)
        echo "ERROR: 不支持的参数: $1" >&2
        exit 1
        ;;
      *)
        services+=("$1")
        shift
        ;;
    esac
  done

  cd "$ROOT"
  gfc_compose_cmd

  if [[ "$detach" -ne 1 ]]; then
    "${COMPOSE[@]}" up "${services[@]}"
    return 0
  fi

  if [[ ${#services[@]} -eq 0 ]]; then
    gfc_compose_safe_up "$ROOT" "$do_build"
    return 0
  fi

  for svc in "${services[@]}"; do
    gfc_compose_safe_up_service "$ROOT" "$svc" "$do_build"
    do_build=0
  done
}

usage() {
  cat <<EOF
GFC 控制平台 Compose 包装器（规避 docker-compose 1.29 ContainerConfig）

用法:
  gfc-compose up -d [api] [web]     安全启动（先删旧容器再 up）
  gfc-compose ensure-webssh         确保容器内 WebSSH PKI 存在
  gfc-compose build [服务...]       构建镜像
  gfc-compose ps | logs | down ...  透传给 compose

勿直接使用: docker-compose up -d web  （可能报 KeyError: ContainerConfig）
勿使用: docker compose …（部分主机仅有 docker-compose v1；请用本包装器）

仓库目录: $ROOT
EOF
}

main() {
  if [[ $# -lt 1 ]]; then
    usage
    exit 1
  fi

  cd "$ROOT"
  gfc_compose_cmd

  case "$1" in
    -h | --help | help)
      usage
      ;;
    up)
      shift
      gfc_compose_cmd_up "$@"
      ;;
    ensure-webssh | ensure-webssh-pki)
      gfc_compose_ensure_webssh_pki "$ROOT"
      ;;
    *)
      "${COMPOSE[@]}" "$@"
      ;;
  esac
}

export GFC_COMPOSE_WRAPPER=1
main "$@"
