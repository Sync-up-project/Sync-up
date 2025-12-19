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

이 프로젝트는 Docker Compose를 사용하여 전체 스택을 실행할 수 있습니다.

### 사전 요구사항

- Docker
- Docker Compose

### 실행 방법

```bash
# 모든 서비스 빌드 및 실행
docker-compose up -d

# 로그 확인
docker-compose logs -f

# 서비스 중지
docker-compose down

# 볼륨까지 삭제하며 중지
docker-compose down -v
```

### 서비스 포트

- Frontend (Next.js): http://localhost:3000
- Backend (NestJS): http://localhost:3001
- PostgreSQL: localhost:5432

### 환경 변수 설정

프로젝트 루트에 `.env` 파일을 생성하고 환경 변수를 설정해야 합니다.

```bash
# .env.example을 복사하여 .env 파일 생성
cp .env.example .env

# 필요에 따라 .env 파일 수정
nano .env
```

`.env` 파일에는 다음 환경 변수들이 포함되어 있습니다:

- **Database**: `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`
- **Backend**: `NODE_ENV`, `DATABASE_HOST`, `DATABASE_PORT`, `DATABASE_USER`, `DATABASE_PASSWORD`, `DATABASE_NAME`
- **Frontend**: `NEXT_PUBLIC_API_URL`

> ⚠️ `.env` 파일은 민감한 정보를 포함하므로 Git에 커밋하지 않습니다. `.env.example` 파일을 참고하세요.
