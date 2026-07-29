#!/usr/bin/env bash
# 编译 Go 引擎并放入 Flutter assets，供桌面 Process 拉起。
# 用法:
#   ./scripts/build-engine-flutter.sh           # 本机 OS/ARCH
#   ./scripts/build-engine-flutter.sh android   # 需要 NDK：ANDROID_NDK_HOME
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT/flutter/assets/engine"
mkdir -p "$OUT_DIR"
TARGET="${1:-host}"
NAME=kotv-engine

cd "$ROOT"

case "$TARGET" in
  host)
    go build -o "$OUT_DIR/$NAME" ./cmd/engine
    cp -f "$OUT_DIR/$NAME" /tmp/kotv-engine 2>/dev/null || true
    chmod +x "$OUT_DIR/$NAME" /tmp/kotv-engine 2>/dev/null || true
    echo "built $OUT_DIR/$NAME"
    ;;
  android|android-arm64)
    : "${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME}"
    API=24
    PREBUILT="$(ls -d "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/* | head -1)"
    CC="$PREBUILT/bin/aarch64-linux-android${API}-clang"
    CGO_ENABLED=1 GOOS=android GOARCH=arm64 CC="$CC" \
      go build -tags kotv_android -o "$OUT_DIR/$NAME" ./cmd/engine
    echo "built android arm64 $OUT_DIR/$NAME"
    ;;
  *)
    echo "usage: $0 [host|android]" >&2
    exit 1
    ;;
esac
