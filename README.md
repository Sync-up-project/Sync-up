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

#### API 주소 구성 (운영)

외부 진입점은 nginx(80) 하나이고, 프론트/백엔드를 같은 도메인 뒤에 둡니다.
설정 파일: [`deploy/nginx/default.conf`](deploy/nginx/default.conf)

| 브라우저 요청 | 전달 대상 |
|---|---|
| `/` | frontend (Next.js) |
| `/backend/*` | backend (NestJS) — 앞의 `/backend` 는 떼고 전달 |
| `/backend/socket.io/*` | backend 채팅 소켓 (websocket) |

- 브라우저는 상대 경로 `/backend` 로 호출하므로 **도메인·IP가 바뀌어도 이미지를 다시 빌드할 필요가 없습니다.**
- `/api` 는 Next.js 자체 API 라우트가 쓰고 있어서 백엔드 경로로 `/backend` 를 사용합니다.
- 주소 결정 로직은 `frontend/src/lib/backendUrl.ts` 한 곳에만 있습니다.

서버를 올릴 때 `.env` 에서 확인할 값:

| 변수 | 운영 값 예시 | 비고 |
|---|---|---|
| `FRONTEND_URL` | `https://<도메인>` | CORS 허용 origin, OAuth 로그인 후 이동 주소 |
| `GITHUB_CALLBACK_URL` | `https://<도메인>/backend/auth/github/callback` | GitHub OAuth App 설정의 callback URL 도 동일하게 변경 |
| `COOKIE_SECURE` | `true` | HTTPS 사용 시 |
| `INTERNAL_BACKEND_URL` | 비워 두거나 `http://backend:3000` | Next 서버 → 백엔드 (컨테이너 내부 통신) |
| `PROD_PUBLIC_API_URL` | 비워 둠 | 백엔드를 별도 서브도메인으로 둘 때만 설정 (빌드 시점 값) |

> ⚠️ `NEXT_PUBLIC_API_URL` 은 개발용 값(`http://localhost:3001`)입니다. 운영 빌드에는 쓰이지 않도록
> `PROD_PUBLIC_API_URL` 로 분리했습니다. `NEXT_PUBLIC_*` 는 빌드 시점에 번들에 박히므로
> 컨테이너 `environment` 로 넘겨도 브라우저 코드에는 반영되지 않습니다.

> 💡 백엔드 쿠키(`refresh_token` 등)는 `path=/auth` 로 발급되는데, nginx 가 `proxy_cookie_path` 로
> `/backend/auth` 로 바꿔 줍니다. nginx 설정을 바꿀 때 이 줄을 지우면 로그인 유지가 깨집니다.

#### AWS(EC2) 배포 절차

API 주소 때문에 코드를 고칠 곳은 없습니다. 서버마다 달라지는 값은 `.env` 와 nginx 설정에만 있습니다.

**1. AWS 콘솔**

| 항목 | 설정 |
|---|---|
| EC2 | Ubuntu 24.04, **t3.small** 이상, 디스크 30GB. 자동 배포(CD)는 GitHub Actions 가 만든 이미지를 받기만 하므로 서버에서 빌드하지 않습니다. 서버에서 직접 빌드(수동 방식)할 거면 t3.medium 또는 스왑 2GB 추가 |
| 보안 그룹 인바운드 | `80`·`443` 은 전체 허용. `3000`·`3001`·`5432` 는 열지 않습니다 (외부 진입점은 nginx 하나). `22` 는 자동 배포 시 GitHub Actions 가 접속해야 하므로 전체 허용하되 **키 인증만** 허용 (`PasswordAuthentication no`) |
| 탄력적 IP | 할당 후 인스턴스에 연결 (없으면 재시작 시 IP 가 바뀜) |
| 도메인 | A 레코드 → 탄력적 IP |
| GitHub OAuth App | Authorization callback URL → `https://<도메인>/backend/auth/github/callback` |

**2. 서버 `.env`** — `cp .env.example .env` 후 아래 값을 변경합니다. (서버에만 두고 커밋 금지)

| 변수 | 운영 값 |
|---|---|
| `NODE_ENV` | `production` |
| `POSTGRES_PASSWORD`, `DATABASE_PASSWORD`, `DATABASE_URL` | 강한 비밀번호로, 세 곳 모두 같은 값 |
| `FRONTEND_URL` | `https://<도메인>` (끝에 `/` 없이, 브라우저 주소와 정확히 일치) |
| `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET` | OAuth App 값 |
| `GITHUB_CALLBACK_URL` | `https://<도메인>/backend/auth/github/callback` |
| `JWT_ACCESS_SECRET`, `JWT_REFRESH_SECRET` | 각각 `openssl rand -hex 32` 로 만든 서로 다른 값 |
| `COOKIE_SECURE` | `true` |
| `PROD_PUBLIC_API_URL` | 비워 둠 |
| `OPENAI_API_KEY` | 실제 키 |

> `FRONTEND_URL` 은 백엔드 CORS, 채팅 소켓 CORS, GitHub 로그인 후 리다이렉트 주소에 모두 쓰입니다.

**3. HTTPS (Let's Encrypt)** — 도메인 없이 IP 로 먼저 띄울 때는 이 단계를 건너뛰고
`FRONTEND_URL=http://<탄력적IP>`, `COOKIE_SECURE=false` 로 둡니다.

nginx 를 띄우기 전(80 포트가 비어 있을 때) 인증서를 발급합니다.

```bash
sudo certbot certonly --standalone -d <도메인>
```

`deploy/nginx/default.conf` 의 `server { listen 80; server_name _;` 부분을 아래로 바꿉니다.
두 `location` 블록은 그대로 둡니다.

```nginx
server {
    listen 80;
    server_name <도메인>;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    http2 on;
    server_name <도메인>;

    ssl_certificate     /etc/letsencrypt/live/<도메인>/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/<도메인>/privkey.pem;

    # ↓ 기존 client_max_body_size, location /backend/, location / 그대로
```

`docker-compose.prod.yml` 의 `nginx` 서비스에 443 포트와 인증서 경로를 추가합니다.

```yaml
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./deploy/nginx/default.conf:/etc/nginx/conf.d/default.conf:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
```

> ⚠️ 자동 배포는 서버에서 `git pull --ff-only` 를 합니다. 서버에서 이 두 파일을 직접 고쳐 두면
> 나중에 레포의 같은 파일이 바뀔 때 pull 이 실패합니다. 도메인이 정해지면 위 변경을 **레포에 커밋**하는 것을 권장합니다.

인증서는 90일마다 갱신해야 하므로 cron 에 등록합니다. (갱신 중에는 80 포트를 비워야 해서 nginx 를 잠시 멈춤)

```bash
sudo certbot renew --pre-hook "docker compose -f /home/ubuntu/Sync-up/docker-compose.prod.yml stop nginx" --post-hook "docker compose -f /home/ubuntu/Sync-up/docker-compose.prod.yml start nginx"
```

**4. 서버 준비** (Docker 는 공식 문서의 Ubuntu 설치 방법으로 설치)

서버에는 루트 레포만 있으면 됩니다. 이미지는 GHCR 에서 받으므로 서브모듈 소스는 필요 없습니다.

```bash
git clone https://github.com/Sync-up-project/Sync-up.git && cd Sync-up
cp .env.example .env && vi .env
```

이후 첫 배포는 아래 [CI/CD](#cicd) 설정을 마친 뒤 GitHub Actions 의 **Deploy → Run workflow** 로 실행합니다.

<details>
<summary>자동 배포 없이 서버에서 직접 빌드·실행하는 방법</summary>

```bash
git clone --recurse-submodules https://github.com/Sync-up-project/Sync-up.git && cd Sync-up
cp .env.example .env && vi .env
docker compose -f docker-compose.prod.yml build
docker compose -f docker-compose.prod.yml --profile migrate run --rm migrate
docker compose -f docker-compose.prod.yml up -d
```

</details>

**5. 올린 뒤 확인**

1. `https://<도메인>/backend/health` → `{"status":"ok"}` (nginx → 백엔드 연결)
2. 일반 로그인 후 새로고침해도 로그인 유지 (쿠키 경로)
3. GitHub 로그인 후 `/projects` 로 복귀 (`FRONTEND_URL`, callback URL)
4. 채팅 송수신 — 개발자 도구 Network 탭에서 `/backend/socket.io` 요청이 `101` 응답인지 확인

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

## CI/CD

```
backend / frontend 레포                              Sync-up (루트) 레포
─────────────────────────                            ─────────────────────────────
PR, main push → CI (lint·타입체크·빌드)
main push     → 이미지 빌드 → GHCR 업로드   ──┐
                (sha-<커밋SHA>, main)          │
                                              └─→   서브모듈 포인터 갱신 push
                                                    → Deploy 워크플로
                                                    → SSH → deploy/deploy.sh
                                                    → pull → migrate → 교체 → 헬스체크
                                                    → 실패 시 직전 버전으로 자동 롤백
```

- **배포 트리거는 루트 레포의 서브모듈 포인터 갱신**입니다. backend/frontend 에 push 만 하면
  이미지는 만들어지지만 운영에는 반영되지 않습니다. (루트 레포 커밋 = 운영에 나간 버전)
- 롤백하려면 루트 레포에서 포인터 갱신 커밋을 revert 하면 이전 이미지로 다시 배포됩니다.

| 워크플로 | 위치 | 하는 일 |
|---|---|---|
| CI | `frontend/.github/workflows/ci.yml` | lint, 타입체크, 빌드 / main 이면 GHCR 업로드 |
| CI | `backend/.github/workflows/ci.yml` | lint, 타입체크, 빌드, **마이그레이션 누락 검사** / main 이면 GHCR 업로드 |
| Deploy | `.github/workflows/deploy.yml` | 서브모듈 포인터가 가리키는 이미지로 운영 서버 배포 |

> backend CI 의 마이그레이션 검사는 빈 DB 에 `prisma/migrations` 를 모두 적용한 뒤 `schema.prisma` 와 비교합니다.
> 스키마만 바꾸고 마이그레이션을 커밋하지 않으면 실패합니다.
> Prettier 포맷 검사는 기존 코드의 포맷 차이 때문에 현재 **경고만** 표시합니다.

### 설정 (AWS 서버를 만든 뒤 1회)

루트 레포 **Settings → Environments → `production`** 에 등록합니다. 필요하면 여기서 배포 승인자(Required reviewers)도 지정할 수 있습니다.

| 종류 | 이름 | 값 |
|---|---|---|
| Secret | `SSH_HOST` | 탄력적 IP 또는 도메인 |
| Secret | `SSH_USER` | `ubuntu` (생략 시 기본값) |
| Secret | `SSH_PRIVATE_KEY` | 배포 전용 개인키 (공개키는 서버 `~/.ssh/authorized_keys` 에 추가) |
| Secret | `SSH_KNOWN_HOSTS` | (선택) `ssh-keyscan <호스트>` 결과. 없으면 배포 때마다 스캔 |
| Secret | `GHCR_TOKEN` | (선택) GHCR 패키지가 private 일 때 `read:packages` 권한 토큰 |
| Variable | `DEPLOY_PATH` | (선택) 서버의 Sync-up 경로, 기본 `/home/ubuntu/Sync-up` |
| Variable | `SSH_PORT` | (선택) 기본 `22` |

- `SSH_HOST` / `SSH_PRIVATE_KEY` 가 없으면 Deploy 는 실패하지 않고 **건너뜁니다.** (서버 준비 전에도 안전)
- GHCR 패키지는 처음 올라갈 때 private 일 수 있습니다. 레포가 public 이므로 GitHub 조직의
  **Packages → backend / frontend → Package settings → Change visibility → Public** 으로 바꾸면 토큰 없이 받을 수 있습니다.
- 배포 전용 키 만들기: `ssh-keygen -t ed25519 -C "github-actions-deploy" -f deploy_key -N ""`

### 서버에서 직접 다룰 때

현재 배포된 이미지 태그는 서버의 `.deploy.env` 에 기록됩니다. compose 를 직접 실행할 때는 이 파일을 함께 넘겨야
같은 버전이 유지됩니다.

```bash
docker compose -f docker-compose.prod.yml --env-file .env --env-file .deploy.env ps
```

특정 버전으로 수동 배포/롤백:

```bash
./deploy/deploy.sh sha-<backend 커밋SHA> sha-<frontend 커밋SHA>
```
