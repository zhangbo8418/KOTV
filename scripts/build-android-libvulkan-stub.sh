#!/usr/bin/env bash
# Build app-local libvulkan.so (Vulkan 1.1 symbol stub) for Android API 25.
# 只进 assets/mpv-libs：真机 Vulkan≥1.2 走系统 libvulkan；若 stub 放进 jniLibs，
# DT_NEEDED 会优先绑到空壳 → 开 gpu-api=vulkan 卡死，且与 FongMi/TV 行为不一致。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${KOTV_VULKAN_STUB_SRC:-$ROOT/flutter/android/native/vkcompat/vkcompat.c}"
OUT_ABI="${1:-arm64-v8a}"
NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK:-}}"
# Prefer ≤28：NDK29+ 链出的产物在部分盒子上无法 exec 外部二进制。
if [[ -z "$NDK" || ! -d "$NDK" ]]; then
  NDK="$(ls -d "$HOME"/Library/Android/sdk/ndk/28.* 2>/dev/null | sort -V | tail -1 || true)"
fi
if [[ -z "$NDK" || ! -d "$NDK" ]]; then
  NDK="$(ls -d "$HOME"/Library/Android/sdk/ndk/* 2>/dev/null | sort -V | grep -v '/ndk/29\.' | tail -1 || true)"
fi
[[ -n "$NDK" && -d "$NDK" ]] || { echo "NDK not found"; exit 1; }
case "$OUT_ABI" in
  arm64-v8a) TRIPLE=aarch64-linux-android; API=24 ;;
  armeabi-v7a) TRIPLE=armv7a-linux-androideabi; API=24 ;;
  *) echo "unsupported abi $OUT_ABI"; exit 1 ;;
esac
CC="$NDK/toolchains/llvm/prebuilt/"*"/bin/${TRIPLE}${API}-clang"
CC=$(echo $CC)
JNI_DIR="$ROOT/flutter/android/app/src/main/jniLibs/$OUT_ABI"
ASSET_DIR="$ROOT/flutter/android/app/src/main/assets/mpv-libs/$OUT_ABI"
mkdir -p "$ASSET_DIR"
OUT="$ASSET_DIR/libvulkan.so"
"$CC" -shared -fPIC -O2 -Wl,-soname,libvulkan.so -o "$OUT" "$SRC"
# 切勿再放进 jniLibs：会盖住系统 Vulkan。
rm -f "$JNI_DIR/libvulkan.so" "$JNI_DIR/libvkcompat.so" "$ASSET_DIR/libvkcompat.so"
echo "built $OUT (assets only; removed jniLibs stub if any)"
# If libmpv still needs libvkcompat, retarget DT_NEEDED.
if command -v patchelf >/dev/null; then
  for mpv in "$JNI_DIR/libmpv.so" "$ASSET_DIR/libmpv.so"; do
    if [[ -f "$mpv" ]] && patchelf --print-needed "$mpv" | grep -q libvkcompat.so; then
      patchelf --replace-needed libvkcompat.so libvulkan.so "$mpv"
      echo "patched DT_NEEDED → libvulkan.so in $mpv"
    fi
  done
fi
