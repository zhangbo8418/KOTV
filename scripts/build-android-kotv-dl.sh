#!/usr/bin/env bash
# Build libkotv_dl.so (JNI helper for RTLD_GLOBAL libvulkan preload).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${KOTV_DL_SRC:-$ROOT/flutter/android/native/kotv_dl/kotv_dl.c}"
OUT_ABI="${1:-arm64-v8a}"
NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK:-}}"
if [[ -z "$NDK" || ! -d "$NDK" ]]; then
  NDK="$(ls -d "$HOME"/Library/Android/sdk/ndk/* 2>/dev/null | sort -V | tail -1 || true)"
fi
[[ -n "$NDK" && -d "$NDK" ]] || { echo "NDK not found" >&2; exit 1; }
case "$OUT_ABI" in
  arm64-v8a) TRIPLE=aarch64-linux-android; API=24 ;;
  armeabi-v7a) TRIPLE=armv7a-linux-androideabi; API=24 ;;
  *) echo "unsupported abi $OUT_ABI" >&2; exit 1 ;;
esac
PREBUILT="$(echo "$NDK"/toolchains/llvm/prebuilt/*)"
CC="$PREBUILT/bin/${TRIPLE}${API}-clang"
OUT_DIR="$ROOT/flutter/android/app/src/main/jniLibs/$OUT_ABI"
ASSET_DIR="$ROOT/flutter/android/app/src/main/assets/mpv-libs/$OUT_ABI"
mkdir -p "$OUT_DIR" "$ASSET_DIR"
OUT="$OUT_DIR/libkotv_dl.so"
"$CC" -shared -fPIC -O2 -Wl,-soname,libkotv_dl.so \
  -o "$OUT" "$SRC" -llog -ldl
cp -f "$OUT" "$ASSET_DIR/libkotv_dl.so"
echo "built $OUT (+ assets copy)"
