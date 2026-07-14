# Docker Compose helpers — avoid docker-compose 1.29 KeyError: ContainerConfig on recreate.
# shellcheck shell=bash

gfc_compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE=(docker compose)
  else
    COMPOSE=(docker-compose)
  fi
}

gfc_compose_project_name() {
  local root=${1:-.}
  if [[ -f "$root/.env" ]]; then
    # shellcheck disable=SC1090
    set -a
    source "$root/.env" 2>/dev/null || true
    set +a
  fi
  if [[ -n "${COMPOSE_PROJECT_NAME:-}" ]]; then
    echo "$COMPOSE_PROJECT_NAME"
    return 0
  fi
  basename "$(cd "$root" && pwd)"
}

gfc_compose_docker_rm_ids() {
  local ids=$1
  if [[ -z "$ids" ]]; then
    return 0
  fi
  # shellcheck disable=SC2086
  docker rm -f $ids 2>/dev/null || true
}

# Remove containers for one compose service (incl. 1.29 orphan names like 7fc07a12794c_project_web_1).
gfc_compose_rm_service_containers() {
  local root=${1:-.}
  local service=${2:?service name required}
  local project
  project=$(gfc_compose_project_name "$root")

  echo "==> 清理 ${project}/${service} 容器"

  gfc_compose_docker_rm_ids "$(
    docker ps -aq \
      --filter "label=com.docker.compose.project=${project}" \
      --filter "label=com.docker.compose.service=${service}" 2>/dev/null || true
  )"

  gfc_compose_docker_rm_ids "$(docker ps -aq --filter "name=${project}_${service}_" 2>/dev/null || true)"
  gfc_compose_docker_rm_ids "$(docker ps -aq --filter "name=_${project}_${service}_" 2>/dev/null || true)"

  case "$service" in
    api)
      docker rm -f gfc_api_1 gfc-platform_api_1 "${project}_api_1" 2>/dev/null || true
      ;;
    web)
      docker rm -f gfc_web_1 gfc-platform_web_1 "${project}_web_1" 2>/dev/null || true
      ;;
  esac
}

# Stop and remove ALL compose containers for this project (including failed recreate orphans).
gfc_compose_rm_project_containers() {
  local root=${1:-.}
  local project
  project=$(gfc_compose_project_name "$root")

  echo "==> 清理 compose 容器 (project=${project})"

  gfc_compose_docker_rm_ids "$(
    docker ps -aq --filter "label=com.docker.compose.project=${project}" 2>/dev/null || true
  )"
  gfc_compose_docker_rm_ids "$(docker ps -aq --filter "name=${project}_" 2>/dev/null || true)"
  gfc_compose_docker_rm_ids "$(docker ps -aq --filter "name=_${project}_" 2>/dev/null || true)"

  docker rm -f gfc_api_1 gfc_web_1 gfc-platform_api_1 gfc-platform_web_1 2>/dev/null || true
}

# Safe up one service: rm its containers first, then up --no-deps (never compose recreate).
gfc_compose_safe_up_service() {
  local root=${1:-.}
  local service=${2:?service name required}
  local do_build=${3:-0}
  cd "$root"
  gfc_compose_cmd
  if [[ "$do_build" == "1" ]]; then
    "${COMPOSE[@]}" build "$service"
  fi
  gfc_compose_rm_service_containers "$root" "$service"
  "${COMPOSE[@]}" up -d --no-deps "$service"
}

# Safe up full stack: rm all project containers first, then up.
gfc_compose_safe_up() {
  local root=${1:-.}
  local do_build=${2:-1}
  cd "$root"
  gfc_compose_cmd
  gfc_compose_rm_project_containers "$root"
  if [[ "$do_build" == "1" ]]; then
    "${COMPOSE[@]}" up -d --build
  else
    "${COMPOSE[@]}" up -d
  fi
}

gfc_compose_wait_api() {
  local port=${1:-8181}
  local tries=${2:-30}
  echo "==> 等待 API healthz"
  for _ in $(seq 1 "$tries"); do
    if curl -fsS "http://127.0.0.1:${port}/healthz" >/dev/null 2>&1; then
      echo "    OK API healthy"
      return 0
    fi
    sleep 2
  done
  echo "    WARN API 未在 ${tries}x2s 内就绪，请检查: gfc-compose logs --tail=50 api"
  return 1
}

gfc_compose_service_container_id() {
  local root=${1:-.}
  local service=${2:?}
  local project
  project=$(gfc_compose_project_name "$root")
  docker ps -q \
    --filter "label=com.docker.compose.project=${project}" \
    --filter "label=com.docker.compose.service=${service}" 2>/dev/null | head -1
}
