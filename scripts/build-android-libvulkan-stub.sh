#!/usr/bin/env bash
# Build app-local libvulkan.so (Vulkan 1.1 symbol stub) for Android API 25+.
# System /system/lib64/libvulkan.so on API 25 lacks 1.1 symbols that libmpv needs;
# shipping as libvulkan.so (not libvkcompat.so) lets DT_NEEDED + loadLibrary resolve
# to the app nativeLibraryDir first.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${KOTV_VULKAN_STUB_SRC:-$ROOT/flutter/android/native/vkcompat/vkcompat.c}"
OUT_ABI="${1:-arm64-v8a}"
NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK:-}}"
if [[ -z "$NDK" || ! -d "$NDK" ]]; then
  NDK="$(ls -d "$HOME"/Library/Android/sdk/ndk/* 2>/dev/null | sort -V | tail -1 || true)"
fi
[[ -n "$NDK" && -d "$NDK" ]] || { echo "NDK not found"; exit 1; }
case "$OUT_ABI" in
  arm64-v8a) TRIPLE=aarch64-linux-android; API=24 ;;
  armeabi-v7a) TRIPLE=armv7a-linux-androideabi; API=24 ;;
  *) echo "unsupported abi $OUT_ABI"; exit 1 ;;
esac
CC="$NDK/toolchains/llvm/prebuilt/"*"/bin/${TRIPLE}${API}-clang"
CC=$(echo $CC)
OUT_DIR="$ROOT/flutter/android/app/src/main/jniLibs/$OUT_ABI"
ASSET_DIR="$ROOT/flutter/android/app/src/main/assets/mpv-libs/$OUT_ABI"
mkdir -p "$OUT_DIR" "$ASSET_DIR"
OUT="$OUT_DIR/libvulkan.so"
"$CC" -shared -fPIC -O2 -Wl,-soname,libvulkan.so -o "$OUT" "$SRC"
cp -f "$OUT" "$ASSET_DIR/libvulkan.so"
rm -f "$OUT_DIR/libvkcompat.so" "$ASSET_DIR/libvkcompat.so"
echo "built $OUT"
# If libmpv still needs libvkcompat, retarget DT_NEEDED.
if command -v patchelf >/dev/null; then
  for mpv in "$OUT_DIR/libmpv.so" "$ASSET_DIR/libmpv.so"; do
    if [[ -f "$mpv" ]] && patchelf --print-needed "$mpv" | grep -q libvkcompat.so; then
      patchelf --replace-needed libvkcompat.so libvulkan.so "$mpv"
      echo "patched DT_NEEDED → libvulkan.so in $mpv"
    fi
  done
fi
