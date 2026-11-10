#!/usr/bin/env bash
# 운영 서버 무중단 배포 스크립트 (docker-rollout 방식).
# (GitHub Actions deploy 워크플로가 SSH 로 실행하며, 서버에서 직접 실행해도 됩니다)
#
#   deploy/deploy.sh <backend 태그> <frontend 태그>   새 버전 배포
#   deploy/deploy.sh rollback                         직전 태그로 되돌리기
#   deploy/deploy.sh status                           현재 상태 출력
#
# 배포 순서
#   1) 새 이미지 pull → DB 마이그레이션
#   2) docker rollout backend : 컨테이너를 2개로 늘려 새 것이 healthy 가 되면 옛 것을 멈추고 지움
#      (새 것이 healthy 가 아니면 docker-rollout 이 새 것만 지우고 실패 → 옛 것은 그대로)
#   3) docker rollout frontend : 같은 방식. 실패하면 backend 도 직전 태그로 다시 rollout
#   4) nginx 설정 반영(reload) → nginx 를 거쳐 스모크 테스트. 실패하면 직전 태그로 rollout
#
# nginx 는 서비스 이름을 매 요청 DNS 로 조회하므로, rollout 중에는 구·신 컨테이너가 함께 요청을 받습니다.
#
# 주의: DB 마이그레이션은 되돌리지 않습니다. rollout 중에는 구·신버전이 같은 DB 로 동시에 서비스하므로
#       마이그레이션은 반드시 이전 버전과 호환되게 작성하세요.
#       (컬럼·테이블 추가는 자유롭게, 삭제·이름 변경은 두 번 이상의 배포로 나눠서)

set -euo pipefail

cd "$(dirname "$0")/.."

# docker-rollout 은 버전을 고정해 설치합니다. (README 의 설치 방법 참고)
ROLLOUT_VERSION=v0.14

STATE_FILE=.deploy.env
HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-180}       # 새 컨테이너가 healthy 가 될 때까지 기다리는 최대 초
WAIT_AFTER_HEALTHY=${WAIT_AFTER_HEALTHY:-3} # healthy 후 옛 컨테이너를 멈추기 전 기다리는 초 (nginx DNS 캐시 1초보다 길게)
DNS_SETTLE=${DNS_SETTLE:-3}                 # 옛 컨테이너를 지운 뒤 다음 단계로 넘어가기 전 기다리는 초 (아래 roll() 설명)

touch "$STATE_FILE"
COMPOSE_ARGS=(-f docker-compose.prod.yml --env-file .env --env-file "$STATE_FILE")
COMPOSE=(docker compose "${COMPOSE_ARGS[@]}")

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

# ---------- 준비 ----------

require_rollout() {
  local installed
  installed=$(docker rollout --version 2> /dev/null || true)
  if [ -z "$installed" ]; then
    log "docker-rollout 이 설치되어 있지 않습니다. README 의 'docker-rollout 설치' 를 따라 $ROLLOUT_VERSION 을 설치하세요."
    exit 1
  fi
  case "$installed" in
    *"$ROLLOUT_VERSION") ;;
    *) log "주의: docker-rollout 버전이 다릅니다. (설치됨: $installed, 검증한 버전: $ROLLOUT_VERSION)" ;;
  esac
}

# ---------- 컨테이너 ----------

# 서비스의 실행 중인 컨테이너가 모두 healthy 가 될 때까지 기다립니다.
wait_healthy() {
  local svc=$1 ids id status waited=0 ok
  while [ "$waited" -lt "$HEALTH_TIMEOUT" ]; do
    ids=$("${COMPOSE[@]}" ps -q "$svc")
    ok=1
    [ -n "$ids" ] || ok=0
    for id in $ids; do
      status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id" 2> /dev/null || echo missing)
      case "$status" in
        healthy) ;;
        unhealthy | exited | dead | missing)
          log "$svc 상태: $status"
          return 1
          ;;
        *) ok=0 ;;
      esac
    done
    if [ "$ok" = 1 ]; then
      log "$svc healthy (${waited}초)"
      return 0
    fi
    sleep 2
    waited=$((waited + 2))
  done
  log "$svc 가 ${HEALTH_TIMEOUT}초 안에 healthy 가 되지 않았습니다."
  return 1
}

# 서비스를 현재 .deploy.env 의 태그로 교체합니다.
roll() {
  local svc=$1
  if [ -z "$("${COMPOSE[@]}" ps -q "$svc")" ]; then
    # 실행 중인 컨테이너가 없으면(첫 배포) docker-rollout 은 기동만 하고 healthy 를 기다리지 않으므로 직접 기다립니다.
    log "$svc 첫 기동"
    "${COMPOSE[@]}" up -d --no-deps "$svc" || return 1
    wait_healthy "$svc"
    return
  fi
  log "$svc rollout (컨테이너 2배 → 새 컨테이너 healthy → 옛 컨테이너 종료)"
  docker rollout "${COMPOSE_ARGS[@]}" --timeout "$HEALTH_TIMEOUT" --wait-after-healthy "$WAIT_AFTER_HEALTHY" "$svc" || return 1
  # 옛 컨테이너가 지워지면 그 IP 가 반납되고, 바로 다음에 만드는 컨테이너(예: 다른 서비스)가 같은 IP 를 받을 수 있습니다.
  # nginx 는 DNS 결과를 1초 캐시하므로, 그사이 옛 IP 로 보낸 요청이 엉뚱한 서비스로 갑니다. (검증 중 실제로 발생: backend 요청이 frontend 404)
  # 캐시가 만료될 때까지 기다린 뒤 다음 단계로 넘어갑니다.
  sleep "$DNS_SETTLE"
}

# ---------- nginx ----------

apply_nginx() {
  # 처음이거나 compose 설정이 바뀌었으면 만들고(바뀌지 않았으면 아무 일도 하지 않음), 설정 파일 변경은 reload 로 반영합니다.
  "${COMPOSE[@]}" up -d --no-deps nginx
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

# ---------- 이미지 정리 ----------

# 현재·직전 태그만 남기고 같은 저장소의 나머지 이미지는 지웁니다. (rollback 용 직전 이미지는 보관)
cleanup_images() {
  local keep repo img prev_b prev_f
  keep=$("${COMPOSE[@]}" config --images 2> /dev/null | sort -u)
  prev_b=$(state_get PREV_BACKEND_TAG)
  prev_f=$(state_get PREV_FRONTEND_TAG)
  for repo in $(echo "$keep" | grep -vE '^(postgres|nginx):' | sed 's/:[^:/]*$//' | sort -u); do
    docker images --format '{{.Repository}}:{{.Tag}}' "$repo" | while read -r img; do
      echo "$keep" | grep -qxF "$img" && continue
      [ -n "$prev_b" ] && [ "${img##*:}" = "$prev_b" ] && continue
      [ -n "$prev_f" ] && [ "${img##*:}" = "$prev_f" ] && continue
      docker rmi "$img" > /dev/null 2>&1 || true
    done
  done
  docker image prune -f > /dev/null 2>&1 || true
}

# ---------- 명령 ----------

# 실패 시 되돌릴 태그 (배포 전 값)
OLD_BACKEND_TAG=""
OLD_FRONTEND_TAG=""

restore_tags() {
  state_set BACKEND_TAG "$OLD_BACKEND_TAG"
  state_set FRONTEND_TAG "$OLD_FRONTEND_TAG"
}

fail() {
  log "배포 실패: $1"
  "${COMPOSE[@]}" logs --tail 30 backend frontend || true
  exit 1
}

deploy() {
  local backend_tag=$1 frontend_tag=$2
  require_rollout

  OLD_BACKEND_TAG=$(state_get BACKEND_TAG)
  OLD_FRONTEND_TAG=$(state_get FRONTEND_TAG)
  log "backend ${OLD_BACKEND_TAG:-없음} → $backend_tag, frontend ${OLD_FRONTEND_TAG:-없음} → $frontend_tag"

  state_set BACKEND_TAG "$backend_tag"
  state_set FRONTEND_TAG "$frontend_tag"

  "${COMPOSE[@]}" --profile migrate pull backend frontend migrate || {
    restore_tags
    fail "이미지 pull 실패 (운영 중인 버전은 그대로)"
  }

  "${COMPOSE[@]}" up -d db
  log "DB 마이그레이션 (rollout 중 구·신버전이 함께 쓰므로 하위 호환이어야 함)"
  "${COMPOSE[@]}" --profile migrate run --rm migrate || {
    restore_tags
    fail "마이그레이션 실패 (운영 중인 버전은 그대로)"
  }

  if ! roll backend; then
    restore_tags
    fail "backend 교체 실패 (docker-rollout 이 새 컨테이너만 지움, 운영 중인 버전은 그대로)"
  fi

  if ! roll frontend; then
    restore_tags
    if [ -n "$OLD_BACKEND_TAG" ] && [ "$OLD_BACKEND_TAG" != "$backend_tag" ]; then
      log "frontend 실패 → backend 도 직전 태그($OLD_BACKEND_TAG)로 되돌립니다."
      roll backend || log "backend 되돌리기 실패. 서버에서 직접 확인이 필요합니다."
    fi
    fail "frontend 교체 실패"
  fi

  apply_nginx || {
    restore_tags
    fail "nginx 설정 적용 실패"
  }

  if ! smoke; then
    log "스모크 테스트 실패 → 직전 태그로 되돌립니다."
    restore_tags
    if [ -n "$OLD_BACKEND_TAG" ]; then
      roll backend || true
      roll frontend || true
    fi
    fail "스모크 테스트 실패"
  fi

  # 성공: 직전 태그를 rollback 용으로 기록 (같은 태그 재배포면 직전 기록 유지)
  if [ -n "$OLD_BACKEND_TAG" ] && { [ "$OLD_BACKEND_TAG" != "$backend_tag" ] || [ "$OLD_FRONTEND_TAG" != "$frontend_tag" ]; }; then
    state_set PREV_BACKEND_TAG "$OLD_BACKEND_TAG"
    state_set PREV_FRONTEND_TAG "$OLD_FRONTEND_TAG"
  fi
  cleanup_images
  log "배포 성공"
}

# rollback 전용: pull·migrate 없이 rollout 만 합니다. 성공하면 현재/직전 태그를 서로 바꿉니다.
deploy_without_migrate() {
  local backend_tag=$1 frontend_tag=$2
  require_rollout
  OLD_BACKEND_TAG=$(state_get BACKEND_TAG)
  OLD_FRONTEND_TAG=$(state_get FRONTEND_TAG)
  state_set BACKEND_TAG "$backend_tag"
  state_set FRONTEND_TAG "$frontend_tag"

  if ! roll backend; then
    restore_tags
    fail "롤백 중 backend 교체 실패 (운영 중인 버전은 그대로)"
  fi
  if ! roll frontend; then
    restore_tags
    roll backend || true
    fail "롤백 중 frontend 교체 실패"
  fi
  smoke || fail "롤백 후 스모크 테스트 실패. 서버에서 직접 확인이 필요합니다."

  state_set PREV_BACKEND_TAG "$OLD_BACKEND_TAG"
  state_set PREV_FRONTEND_TAG "$OLD_FRONTEND_TAG"
}

rollback() {
  local prev_b prev_f
  prev_b=$(state_get PREV_BACKEND_TAG)
  prev_f=$(state_get PREV_FRONTEND_TAG)
  if [ -z "$prev_b" ] || [ -z "$prev_f" ]; then
    log "직전 배포 기록이 없어 롤백할 수 없습니다."
    exit 1
  fi
  log "롤백: backend $(state_get BACKEND_TAG) → $prev_b, frontend $(state_get FRONTEND_TAG) → $prev_f"
  # 이미지는 cleanup_images 가 보관해 두었으므로 새로 받지 않고, 마이그레이션도 하지 않습니다.
  deploy_without_migrate "$prev_b" "$prev_f"
  log "롤백 완료"
}

status() {
  echo "현재: backend=$(state_get BACKEND_TAG) frontend=$(state_get FRONTEND_TAG)"
  echo "직전: backend=$(state_get PREV_BACKEND_TAG) frontend=$(state_get PREV_FRONTEND_TAG)"
  echo "docker-rollout: $(docker rollout --version 2> /dev/null || echo '설치 안 됨')"
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
