#!/usr/bin/env bash
# 构建不依赖宿主 glibc 的 Linux 引擎：musl 全静态（QuickJS/libutp 编进二进制）。
# runtime/（JRE/Python 等）仍外置。
#
# 用法: ./scripts/build-engine-static-linux.sh <out-path> [amd64|arm64]
# 优先本机 musl-gcc（同 arch），否则 Docker golang:*-alpine。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?usage: $0 <out-path> [amd64|arm64]}"
ARCH="${2:-amd64}"
VERSION="${KOTV_VERSION:-${VERSION:-0.0.0}}"
VERSION="${VERSION#v}"

case "$ARCH" in
  amd64|x86_64|linux-x64) GOARCH=amd64; DOCKER_PLATFORM=linux/amd64 ;;
  arm64|aarch64|linux-arm64) GOARCH=arm64; DOCKER_PLATFORM=linux/arm64 ;;
  *) echo "unknown arch: $ARCH" >&2; exit 1 ;;
esac

mkdir -p "$(dirname "$OUT")"
ABS_OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
# Docker 挂载 ROOT 时写入相对路径
TMP_REL="dist/.kotv-engine-static-$GOARCH"
TMP_ABS="$ROOT/$TMP_REL"
mkdir -p "$(dirname "$TMP_ABS")"

LDFLAGS="-s -w -X github.com/bobo/KOTV/internal/update.CurrentVersion=${VERSION} -linkmode external -extldflags '-static'"
IMAGE="${KOTV_STATIC_GO_IMAGE:-golang:1.26-alpine}"

(cd "$ROOT/internal/spider" && go run gen_qjsinc.go)

host_goarch="$(go env GOARCH 2>/dev/null || true)"
# 优先 Docker Alpine（自带 musl + g++，QuickJS/libutp C++ 都能静态链）
# 本机仅 musl-gcc 时 C++ 易链到 glibc，不可靠。
if command -v docker >/dev/null 2>&1; then
  echo "==> static engine via Docker $IMAGE ($DOCKER_PLATFORM)"
  docker run --rm --platform "$DOCKER_PLATFORM" \
    -v "$ROOT:/src" -w /src \
    -e CGO_ENABLED=1 \
    -e GOOS=linux \
    -e GOARCH="$GOARCH" \
    "$IMAGE" \
    sh -ec "
      apk add --no-cache build-base git
      cd /src/internal/spider && go run gen_qjsinc.go
      cd /src
      go build -ldflags \"$LDFLAGS\" -o /src/$TMP_REL ./cmd/engine
    "
elif [[ "$(uname -s)" == "Linux" ]] && command -v musl-gcc >/dev/null 2>&1 && [[ "$GOARCH" == "$host_goarch" ]]; then
  echo "==> static engine via musl-gcc (GOARCH=$GOARCH; 若 C++ 链接失败请改用 Docker)"
  (cd "$ROOT" && \
    CGO_ENABLED=1 GOOS=linux GOARCH="$GOARCH" CC=musl-gcc CXX="${CXX:-musl-gcc}" \
    go build -ldflags "$LDFLAGS" -o "$TMP_ABS" ./cmd/engine)
else
  echo "ERROR: Linux 全静态引擎需要 Docker（推荐）或 musl-gcc" >&2
  exit 1
fi

cp -f "$TMP_ABS" "$ABS_OUT"
rm -f "$TMP_ABS"
chmod +x "$ABS_OUT" 2>/dev/null || true

if command -v file >/dev/null 2>&1; then
  file "$ABS_OUT" || true
fi
if command -v ldd >/dev/null 2>&1; then
  if ldd "$ABS_OUT" >/dev/null 2>&1; then
    echo "ERROR: 仍为动态链接，未摆脱 glibc:" >&2
    ldd "$ABS_OUT" >&2 || true
    exit 1
  fi
  echo "OK: statically linked"
fi
ls -lh "$ABS_OUT"
