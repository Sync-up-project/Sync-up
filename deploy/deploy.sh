#!/usr/bin/env bash
# 운영 서버 블루-그린 무중단 배포 스크립트.
# (GitHub Actions deploy 워크플로가 SSH 로 실행하며, 서버에서 직접 실행해도 됩니다)
#
#   deploy/deploy.sh <backend 태그> <frontend 태그>   대기 중인 색에 새 버전을 띄우고 전환
#   deploy/deploy.sh rollback                         직전 색으로 되돌리기
#   deploy/deploy.sh status                           현재 상태 출력
#
# 배포 순서
#   1) 대기 색(활성의 반대)에 새 이미지 pull → DB 마이그레이션
#   2) 대기 색 backend → frontend 기동, Docker 헬스체크가 healthy 가 될 때까지 대기
#      실패하면 대기 색만 정리하고 끝냅니다. 운영 중인 활성 색은 전혀 건드리지 않습니다.
#   3) nginx upstream 을 대기 색으로 바꾸고 reload (처리 중인 요청은 끊기지 않음)
#   4) nginx 를 거쳐 스모크 테스트. 실패하면 upstream 을 되돌립니다.
#   5) 드레이닝 대기 후 이전 색을 멈춥니다. 지우지 않고 남겨 두어 rollback 에 씁니다.
#
# 주의: DB 마이그레이션은 되돌리지 않습니다. 전환 직전까지 이전 버전이 같은 DB 로 서비스하므로
#       마이그레이션은 반드시 이전 버전과 호환되게 작성하세요.
#       (컬럼·테이블 추가는 자유롭게, 삭제·이름 변경은 두 번 이상의 배포로 나눠서)

set -euo pipefail

cd "$(dirname "$0")/.."

STATE_FILE=.deploy.env
ACTIVE_DIR=deploy/nginx/active
UPSTREAM_FILE=$ACTIVE_DIR/upstream.conf

HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-180} # 새 색이 healthy 가 될 때까지 기다리는 최대 초
DRAIN_SECONDS=${DRAIN_SECONDS:-15}    # 전환 후 이전 색을 멈추기 전에 기다리는 초

touch "$STATE_FILE"
COMPOSE=(docker compose -f docker-compose.prod.yml --env-file .env --env-file "$STATE_FILE")

log() { echo "[deploy] $*"; }

usage() {
  sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

# ---------- 상태 파일 (.deploy.env) ----------

state_get() {
  sed -n "s/^$1=//p" "$STATE_FILE" | tail -n 1
}

state_set() {
  local key=$1 value=$2 tmp
  tmp=$(mktemp "$STATE_FILE.XXXXXX")
  grep -v "^$key=" "$STATE_FILE" > "$tmp" || true
  echo "$key=$value" >> "$tmp"
  mv "$tmp" "$STATE_FILE"
}

other() { if [ "$1" = blue ]; then echo green; else echo blue; fi; }
upper() { echo "$1" | tr '[:lower:]' '[:upper:]'; }

# ---------- 컨테이너 ----------

wait_healthy() {
  local svc=$1 cid status waited=0
  cid=$("${COMPOSE[@]}" ps -a -q "$svc")
  if [ -z "$cid" ]; then
    log "$svc 컨테이너가 없습니다."
    return 1
  fi
  while [ "$waited" -lt "$HEALTH_TIMEOUT" ]; do
    status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid" 2>/dev/null || echo missing)
    case "$status" in
      healthy)
        log "$svc healthy (${waited}초)"
        return 0
        ;;
      unhealthy | exited | dead | missing)
        log "$svc 상태: $status"
        return 1
        ;;
    esac
    sleep 2
    waited=$((waited + 2))
  done
  log "$svc 가 ${HEALTH_TIMEOUT}초 안에 healthy 가 되지 않았습니다."
  return 1
}

stop_color() {
  log "$1 색을 멈춥니다. (진행 중인 AI 작업이 있으면 끝날 때까지 기다림)"
  "${COMPOSE[@]}" stop "frontend-$1" "backend-$1" || true
}

show_logs() {
  "${COMPOSE[@]}" logs --tail 50 "backend-$1" "frontend-$1" || true
}

# ---------- nginx ----------

write_upstream() {
  local tmp="$ACTIVE_DIR/.upstream.conf.tmp"
  mkdir -p "$ACTIVE_DIR"
  printf 'upstream syncup_backend  { server backend-%s:3000; }\nupstream syncup_frontend { server frontend-%s:3000; }\n' "$1" "$1" > "$tmp"
  # 같은 폴더 안에서 mv 해야 원자적으로 교체됩니다.
  mv "$tmp" "$UPSTREAM_FILE"
}

reload_nginx() {
  "${COMPOSE[@]}" exec -T nginx nginx -t -q && "${COMPOSE[@]}" exec -T nginx nginx -s reload
}

smoke() {
  local i
  for i in 1 2 3 4 5; do
    if "${COMPOSE[@]}" exec -T nginx wget -qO /dev/null http://127.0.0.1:8081/healthz/backend &&
      "${COMPOSE[@]}" exec -T nginx wget -qO /dev/null http://127.0.0.1:8081/healthz/frontend; then
      return 0
    fi
    sleep 2
  done
  return 1
}

# nginx 가 가리키는 색을 바꿉니다. 실패하면 이전 upstream 으로 되돌리고 1 을 반환합니다.
switch_to() {
  local target=$1 previous=$2 backup=""
  [ -f "$UPSTREAM_FILE" ] && backup=$(cat "$UPSTREAM_FILE")

  write_upstream "$target"

  if [ -z "$previous" ]; then
    # 첫 블루-그린 배포: nginx 를 새 설정으로 다시 만들고, 이전 구성의 backend/frontend 단일 서비스를 정리합니다.
    # (이전 구성에서 넘어올 때 한 번만 1~2초 끊길 수 있음)
    "${COMPOSE[@]}" up -d --no-deps --force-recreate --remove-orphans nginx || return 1
  elif ! reload_nginx; then
    log "nginx 설정 적용 실패 → upstream 을 되돌립니다."
    [ -n "$backup" ] && printf '%s\n' "$backup" > "$UPSTREAM_FILE"
    return 1
  fi

  sleep 1
  if ! smoke; then
    log "스모크 테스트 실패 → upstream 을 되돌립니다."
    if [ -n "$backup" ]; then
      printf '%s\n' "$backup" > "$UPSTREAM_FILE"
      reload_nginx || true
    fi
    return 1
  fi

  state_set ACTIVE_COLOR "$target"
  log "전환 완료. 운영 중인 색: $target"
}

# ---------- 이미지 정리 ----------

# blue/green 이 참조하는 태그만 남기고, 같은 저장소의 나머지 이미지는 지웁니다. (디스크 보호)
cleanup_images() {
  local keep repo img
  keep=$("${COMPOSE[@]}" config --images 2>/dev/null | sort -u)
  for repo in $(echo "$keep" | grep -vE '^(postgres|nginx):' | sed 's/:[^:/]*$//' | sort -u); do
    docker images --format '{{.Repository}}:{{.Tag}}' "$repo" | while read -r img; do
      echo "$keep" | grep -qxF "$img" || docker rmi "$img" > /dev/null 2>&1 || true
    done
  done
  docker image prune -f > /dev/null 2>&1 || true
}

# ---------- 명령 ----------

# 배포 전 대상 색의 기록. 실패하면 이 값으로 되돌려 rollback 대상이 망가지지 않게 합니다.
RESTORE_STATE=()

fail_target() {
  local kv
  log "배포 실패: $2"
  show_logs "$1"
  stop_color "$1"
  for kv in "${RESTORE_STATE[@]}"; do
    state_set "${kv%%=*}" "${kv#*=}"
  done
  log "운영 중인 색은 그대로입니다: $(state_get ACTIVE_COLOR || true)"
  exit 1
}

deploy() {
  local backend_tag=$1 frontend_tag=$2 active target T
  active=$(state_get ACTIVE_COLOR)
  if [ -n "$active" ]; then target=$(other "$active"); else target=blue; fi
  T=$(upper "$target")
  log "활성: ${active:-없음} → 대상: $target (backend=$backend_tag frontend=$frontend_tag)"

  RESTORE_STATE=(
    "${T}_BACKEND_TAG=$(state_get "${T}_BACKEND_TAG")"
    "${T}_FRONTEND_TAG=$(state_get "${T}_FRONTEND_TAG")"
    "MIGRATE_TAG=$(state_get MIGRATE_TAG)"
  )
  state_set "${T}_BACKEND_TAG" "$backend_tag"
  state_set "${T}_FRONTEND_TAG" "$frontend_tag"
  state_set MIGRATE_TAG "$backend_tag"

  "${COMPOSE[@]}" --profile migrate pull "backend-$target" "frontend-$target" migrate ||
    fail_target "$target" "이미지 pull 실패"

  "${COMPOSE[@]}" up -d db
  log "DB 마이그레이션 (이전 버전이 계속 서비스하는 중이므로 하위 호환이어야 함)"
  "${COMPOSE[@]}" --profile migrate run --rm migrate || fail_target "$target" "마이그레이션 실패"

  "${COMPOSE[@]}" up -d --no-deps --force-recreate "backend-$target" || fail_target "$target" "backend 기동 실패"
  wait_healthy "backend-$target" || fail_target "$target" "backend 헬스체크 실패"
  "${COMPOSE[@]}" up -d --no-deps --force-recreate "frontend-$target" || fail_target "$target" "frontend 기동 실패"
  wait_healthy "frontend-$target" || fail_target "$target" "frontend 헬스체크 실패"

  switch_to "$target" "$active" || fail_target "$target" "전환 실패"

  if [ -n "$active" ]; then
    log "${DRAIN_SECONDS}초 드레이닝 후 이전 색($active)을 멈춥니다. (지우지 않음 → rollback 에 사용)"
    sleep "$DRAIN_SECONDS"
    stop_color "$active"
  fi

  cleanup_images
  log "배포 성공"
}

rollback_fail() {
  log "롤백 실패"
  show_logs "$1"
  stop_color "$1"
  log "운영 중인 색은 그대로입니다: $2"
  exit 1
}

rollback() {
  local active previous P
  active=$(state_get ACTIVE_COLOR)
  if [ -z "$active" ]; then
    log "활성 색 기록이 없어 롤백할 수 없습니다."
    exit 1
  fi
  previous=$(other "$active")
  P=$(upper "$previous")
  if [ -z "$(state_get "${P}_BACKEND_TAG")" ]; then
    log "$previous 색으로 배포된 기록이 없어 롤백할 수 없습니다."
    exit 1
  fi
  log "롤백: $active → $previous (backend=$(state_get "${P}_BACKEND_TAG") frontend=$(state_get "${P}_FRONTEND_TAG"))"

  # 멈춰 둔 컨테이너가 있으면 그대로 다시 시작합니다. (이미지를 새로 받거나 마이그레이션하지 않음)
  "${COMPOSE[@]}" up -d --no-deps "backend-$previous" || rollback_fail "$previous" "$active"
  wait_healthy "backend-$previous" || rollback_fail "$previous" "$active"
  "${COMPOSE[@]}" up -d --no-deps "frontend-$previous" || rollback_fail "$previous" "$active"
  wait_healthy "frontend-$previous" || rollback_fail "$previous" "$active"

  switch_to "$previous" "$active" || rollback_fail "$previous" "$active"
  log "${DRAIN_SECONDS}초 드레이닝 후 $active 를 멈춥니다."
  sleep "$DRAIN_SECONDS"
  stop_color "$active"
  log "롤백 완료"
}

status() {
  local c C
  echo "활성 색: $(state_get ACTIVE_COLOR || true)"
  for c in blue green; do
    C=$(upper "$c")
    echo "$c: backend=$(state_get "${C}_BACKEND_TAG") frontend=$(state_get "${C}_FRONTEND_TAG")"
  done
  "${COMPOSE[@]}" ps -a
}

case "${1:-}" in
  rollback) rollback ;;
  status) status ;;
  "" | -h | --help) usage ;;
  *)
    [ "$#" -eq 2 ] || usage
    deploy "$1" "$2"
    ;;
esac
