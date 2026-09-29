#!/usr/bin/env bash
# 운영 서버 배포 스크립트. (GitHub Actions deploy 워크플로가 SSH 로 실행, 수동 실행도 가능)
#
#   사용법: deploy/deploy.sh <backend 이미지 태그> <frontend 이미지 태그>
#   예)     deploy/deploy.sh sha-1a2b3c... sha-4d5e6f...
#
# 순서: 이미지 pull → DB 마이그레이션 → 컨테이너 교체 → 헬스체크
# 헬스체크에 실패하면 직전 버전(.deploy.env)으로 되돌리고 실패로 종료합니다.
# (DB 마이그레이션은 되돌리지 않습니다. 마이그레이션은 이전 버전과 호환되게 작성하세요.)

set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "사용법: $0 <backend_tag> <frontend_tag>" >&2
  exit 2
fi

cd "$(dirname "$0")/.."

STATE_FILE=.deploy.env
COMPOSE=(docker compose -f docker-compose.prod.yml --env-file .env --env-file "$STATE_FILE" --profile migrate)

HEALTH_RETRIES=${HEALTH_RETRIES:-30}
HEALTH_INTERVAL=${HEALTH_INTERVAL:-5}

log() { echo "[deploy] $*"; }

read_state() {
  # .deploy.env 에서 KEY 값을 읽습니다. (source 하지 않고 필요한 키만 파싱)
  [ -f "$STATE_FILE" ] && sed -n "s/^$1=//p" "$STATE_FILE" | tail -n 1
}

write_state() {
  printf 'BACKEND_TAG=%s\nFRONTEND_TAG=%s\n' "$1" "$2" > "$STATE_FILE"
}

healthy() {
  local i
  for i in $(seq 1 "$HEALTH_RETRIES"); do
    if curl -fsS -o /dev/null http://127.0.0.1:3001/health &&
       curl -fsS -o /dev/null http://127.0.0.1:3000/; then
      return 0
    fi
    sleep "$HEALTH_INTERVAL"
  done
  return 1
}

# 이미지를 받아 교체합니다. set -e 는 if 조건 안에서 꺼지므로 단계마다 명시적으로 실패를 반환합니다.
switch_to() {
  local backend_tag=$1 frontend_tag=$2
  write_state "$backend_tag" "$frontend_tag"
  log "backend=$backend_tag frontend=$frontend_tag"

  "${COMPOSE[@]}" pull backend frontend migrate || return 1
  "${COMPOSE[@]}" run --rm migrate || return 1
  "${COMPOSE[@]}" up -d --no-build --remove-orphans || return 1
  healthy || return 1
}

prev_backend=$(read_state BACKEND_TAG || true)
prev_frontend=$(read_state FRONTEND_TAG || true)

if switch_to "$1" "$2"; then
  log "배포 성공"
  docker image prune -f >/dev/null || true
  exit 0
fi

log "배포 실패 (헬스체크 또는 컨테이너 기동 실패)"
"${COMPOSE[@]}" ps || true
"${COMPOSE[@]}" logs --tail 50 backend frontend || true

if [ -n "$prev_backend" ] && [ -n "$prev_frontend" ]; then
  log "직전 버전으로 롤백합니다."
  write_state "$prev_backend" "$prev_frontend"
  if "${COMPOSE[@]}" up -d --no-build --remove-orphans && healthy; then
    log "롤백 완료: backend=$prev_backend frontend=$prev_frontend"
  else
    log "롤백도 실패했습니다. 서버에서 직접 확인이 필요합니다."
  fi
else
  log "직전 배포 기록이 없어 롤백하지 않습니다."
fi
exit 1
