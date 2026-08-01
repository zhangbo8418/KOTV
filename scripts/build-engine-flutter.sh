#!/usr/bin/env bash
# 编译 Go 引擎并放入 Flutter assets（桌面）或 jniLibs（Android）。
# 用法:
#   ./scripts/build-engine-flutter.sh              # 本机 OS/ARCH
#   ./scripts/build-engine-flutter.sh android       # arm64 + armeabi-v7a（需 NDK）
#   ./scripts/build-engine-flutter.sh android-arm64
#   ./scripts/build-engine-flutter.sh android-arm
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT/flutter/assets/engine"
mkdir -p "$OUT_DIR"
TARGET="${1:-host}"
NAME=kotv-engine

cd "$ROOT"

resolve_ndk() {
  if [[ -n "${ANDROID_NDK_HOME:-}" && -d "${ANDROID_NDK_HOME}" ]]; then
    return
  fi
  for cand in \
    "$HOME/Library/Android/sdk/ndk"/* \
    "$HOME/Android/Sdk/ndk"/* \
    /usr/local/lib/android/sdk/ndk/* \
    "${ANDROID_HOME:-}/ndk"/*
  do
    if [[ -d "$cand" ]]; then
      ANDROID_NDK_HOME="$cand"
      return
    fi
  done
  : "${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME or install Android NDK}"
}

build_android_abi() {
  local abi="$1"  # arm64-v8a | armeabi-v7a
  local api=24
  local prebuilt cc goarch goarm=""
  prebuilt="$(ls -d "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/* | head -1)"
  case "$abi" in
    arm64-v8a)
      cc="$prebuilt/bin/aarch64-linux-android${api}-clang"
      goarch=arm64
      ;;
    armeabi-v7a)
      cc="$prebuilt/bin/armv7a-linux-androideabi${api}-clang"
      goarch=arm
      goarm=7
      ;;
    *)
      echo "unsupported abi: $abi" >&2
      exit 1
      ;;
  esac
  local jni_dir="$ROOT/flutter/android/app/src/main/jniLibs/$abi"
  mkdir -p "$jni_dir"
  echo "==> android $abi (GOARCH=$goarch${goarm:+ GOARM=$goarm})"
  if [[ -n "$goarm" ]]; then
    CGO_ENABLED=1 GOOS=android GOARCH="$goarch" GOARM="$goarm" CC="$cc" \
      go build -tags kotv_android -o "$jni_dir/libkotv_engine.so" ./cmd/engine
  else
    CGO_ENABLED=1 GOOS=android GOARCH="$goarch" CC="$cc" \
      go build -tags kotv_android -o "$jni_dir/libkotv_engine.so" ./cmd/engine
  fi
  # arm64 再拷一份到 assets 便于校验；v7 只进 jniLibs。
  if [[ "$abi" == "arm64-v8a" ]]; then
    cp -f "$jni_dir/libkotv_engine.so" "$OUT_DIR/libkotv_engine.so"
  fi
  echo "built $jni_dir/libkotv_engine.so"
}

case "$TARGET" in
  host)
    go build -o "$OUT_DIR/$NAME" ./cmd/engine
    cp -f "$OUT_DIR/$NAME" /tmp/kotv-engine 2>/dev/null || true
    chmod +x "$OUT_DIR/$NAME" /tmp/kotv-engine 2>/dev/null || true
    echo "built $OUT_DIR/$NAME"
    ;;
  android)
    resolve_ndk
    build_android_abi arm64-v8a
    build_android_abi armeabi-v7a
    ;;
  android-arm64)
    resolve_ndk
    build_android_abi arm64-v8a
    ;;
  android-arm|android-armv7|android-armeabi-v7a)
    resolve_ndk
    build_android_abi armeabi-v7a
    ;;
  *)
    echo "usage: $0 [host|android|android-arm64|android-arm]" >&2
    exit 1
    ;;
esac
