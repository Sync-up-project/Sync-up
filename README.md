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
