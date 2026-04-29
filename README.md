# Sync-up

## 클론 방법

이 레포지토리는 backend와 frontend 서브모듈을 포함하고 있습니다.

### 서브모듈까지 함께 클론하기 (권장)

```bash
git clone --recurse-submodules https://github.com/Sync-up-project/Sync-up.git
```

또는

```bash
git clone --recursive https://github.com/Sync-up-project/Sync-up.git
```

### 일반 클론 후 서브모듈 초기화

```bash
git clone https://github.com/Sync-up-project/Sync-up.git
cd Sync-up
git submodule update --init --recursive
```

## 서브모듈 업데이트

서브모듈을 최신 버전으로 업데이트하려면:

```bash
git submodule update --remote
```

## Docker Compose로 실행하기

이 프로젝트는 개발(dev)과 운영(prod)을 분리해 두 개의 compose 파일로 관리합니다.

- `docker-compose.yml` — 개발 전용 (호스트 코드 마운트 + watch)
- `docker-compose.prod.yml` — 운영 전용 (멀티스테이지 빌드 + standalone)

### 사전 요구사항

- Docker
- Docker Compose v2 (`docker compose` 명령)
- 루트에 `.env` 파일 (없으면 `cp .env.example .env`)

### 개발 모드

```bash
# 최초 한 번 (or Dockerfile.dev 변경 시) 이미지 빌드
docker compose build

# 백/프론트/DB 같이 실행
docker compose up

# 백그라운드 실행
docker compose up -d

# 로그 보기
docker compose logs -f backend
```

- 호스트의 `./backend`, `./frontend` 가 컨테이너에 마운트되어 변경 시 자동 재시작.
- `node_modules` 는 이름 있는 볼륨(`backend_node_modules`, `frontend_node_modules`)에 캐시되어
  `package-lock.json` 이 바뀐 경우에만 `npm ci` 를 다시 돌려요.
- `prisma generate` 도 `prisma/schema.prisma` 가 바뀐 경우에만 자동으로 다시 돌아갑니다.

#### 자주 쓰는 작업

```bash
# 컨테이너 안에서 명령 실행
docker compose exec backend npx nest --help
docker compose exec backend npx prisma migrate dev --name <migration-name>

# Prisma Studio (호스트 브라우저: http://localhost:5555)
docker compose exec backend npx prisma studio -p 5555 -b none

# 의존성/캐시까지 깨끗이 지우고 다시 시작
docker compose down -v
docker compose build --no-cache
docker compose up
```

> `docker compose down` 만 하면 DB 볼륨(`postgres_data`)은 보존됩니다.
> DB까지 초기화하고 싶을 때만 `down -v` 를 사용하세요.

### 운영(prod) 모드

```bash
# 이미지 빌드 (멀티스테이지)
docker compose -f docker-compose.prod.yml build

# DB 스키마 마이그레이션 (필요 시 1회)
docker compose -f docker-compose.prod.yml --profile migrate run --rm migrate

# 서비스 기동
docker compose -f docker-compose.prod.yml up -d
```

- 백엔드는 `nest build` 로 만들어진 `dist/main` 만 실행하고,
  프론트엔드는 Next.js standalone 산출물(`server.js`)만 실행합니다.
- 마이그레이션은 별도 일회성 잡(`migrate` 프로필)으로 분리되어 자동 실행되지 않습니다.

### 서비스 포트

- Frontend (Next.js): http://localhost:3000
- Backend (NestJS): http://localhost:3001
- Prisma Studio (개발): http://localhost:5555
- PostgreSQL: 127.0.0.1:5432 (개발 모드에서 호스트 로컬에만 바인딩)

### 환경 변수

프로젝트 루트의 `.env` 가 모든 서비스에서 읽힙니다. 처음에는 `.env.example` 을 복사해 사용하세요.

```bash
cp .env.example .env
```

> ⚠️ `.env` 는 민감한 값을 포함하므로 커밋하지 마세요. 운영 환경에서는 별도 비밀 관리 도구를 권장합니다.
