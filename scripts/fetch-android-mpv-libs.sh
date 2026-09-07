#!/usr/bin/env bash
# 拉取 Android 原生 MPV（libmpv + libplayer JNI），放入 assets/mpv-libs。
# 来源：fish2018/webhtv 随 APK 打包的预编译库（与 is.xyz.mpv.MPVLib 配套）。
set -euo pipefail

# App-local libvulkan.so (Vulkan 1.1 symbol stub) is NOT fetched from upstream.
# Keep flutter/android/app/src/main/jniLibs/<abi>/libvulkan.so (+ assets sync) and
# ensure libmpv DT_NEEDED is libvulkan.so (not libvkcompat.so):
#   patchelf --replace-needed libvkcompat.so libvulkan.so libmpv.so
# Rebuild stub from .tmp/vkcompat/vkcompat.c as libvulkan.so (-soname libvulkan.so).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSET="$ROOT/flutter/android/app/src/main/assets/mpv-libs"
BASE="${KOTV_MPV_LIBS_BASE:-https://raw.githubusercontent.com/fish2018/webhtv/main/app/src}"

libs=(
  "libc++_shared.so"
  "libmpv.so"
  "libmvcodec.so"
  "libmvdevice.so"
  "libmvfilter.so"
  "libmvformat.so"
  "libmvutil.so"
  "libmwresample.so"
  "libmwscale.so"
  "libplayer.so"
)

fetch_abi() {
  local abi="$1" src_flavor="$2"
  local dest="$ASSET/$abi"
  mkdir -p "$dest"
  local lib
  for lib in "${libs[@]}"; do
    local out="$dest/$lib"
    if [[ -f "$out" && -s "$out" ]]; then
      echo "ok $abi/$lib ($(wc -c <"$out" | tr -d ' ') bytes)"
      continue
    fi
    local enc="${lib//+/%2B}"
    local url="$BASE/$src_flavor/assets/mpv-libs/$abi/$enc"
    echo "GET $url"
    curl -fL --retry 5 --retry-delay 2 -o "$out.partial" "$url"
    mv "$out.partial" "$out"
    echo "saved $abi/$lib ($(wc -c <"$out" | tr -d ' ') bytes)"
  done
}

echo "==> fetch Android MPV libs → $ASSET"
fetch_abi arm64-v8a arm64_v8a
fetch_abi armeabi-v7a armeabi_v7a
echo "==> done"
du -sh "$ASSET"/* 2>/dev/null || true
