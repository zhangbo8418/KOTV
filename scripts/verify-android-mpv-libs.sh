#!/usr/bin/env bash
# 校验 Android MPV：套件在 jniLibs；Vulkan stub 仅在 assets（勿双份）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/android-mpv-lib-names.sh
source "$ROOT/scripts/android-mpv-lib-names.sh"
ASSET="$ROOT/flutter/android/app/src/main/assets/mpv-libs"
JNI_ROOT="$ROOT/flutter/android/app/src/main/jniLibs"
fail=0

check_abi() {
  local abi="$1"
  local asset_dir="$ASSET/$abi"
  local jni="$JNI_ROOT/$abi"
  local mpv="$jni/libmpv.so"
  local ffmpeg="$jni/libffmpeg.so"
  local vulkan_asset="$asset_dir/libvulkan.so"
  local vulkan_jni="$jni/libvulkan.so"
  local cxx_jni="$jni/libc++_shared.so"
  local lib

  [[ -f "$mpv" ]] || { echo "ERROR: missing $mpv" >&2; fail=1; return; }
  [[ -f "$ffmpeg" ]] || { echo "ERROR: missing $ffmpeg" >&2; fail=1; return; }
  [[ -f "$cxx_jni" ]] || { echo "ERROR: missing $cxx_jni" >&2; fail=1; return; }
  [[ -f "$vulkan_asset" ]] || { echo "ERROR: missing $vulkan_asset (API25 stub in assets)" >&2; fail=1; return; }
  if [[ -f "$vulkan_jni" ]]; then
    echo "ERROR: $vulkan_jni must not exist (stub in jniLibs steals system Vulkan)" >&2
    fail=1
    return
  fi
  for lib in "${KOTV_ANDROID_MPV_ASSET_FORBIDDEN[@]}"; do
    if [[ -f "$asset_dir/$lib" ]]; then
      echo "ERROR: duplicate $asset_dir/$lib (must live only in jniLibs)" >&2
      fail=1
    fi
  done
  echo "ok $abi: libvulkan stub in assets only; suite in jniLibs"

  if grep -aqE 'vulkan|androidvk|-Dvulkan=enabled' "$mpv" 2>/dev/null; then
    echo "ok $abi/libmpv.so: vulkan"
  else
    echo "ERROR: $abi/libmpv.so lacks vulkan (re-run prepare-android-mpv-native.sh)" >&2
    fail=1
  fi

  if grep -aqE 'libarcdav3a|AV3A Audio Vivid|--enable-libarcdav3a' "$ffmpeg" 2>/dev/null; then
    echo "ok $abi/libffmpeg.so: AV3A (libarcdav3a)"
  else
    echo "ERROR: $abi/libffmpeg.so lacks AV3A (re-run FongMi source build)" >&2
    fail=1
  fi

  if grep -aqE 'av_dovi_rpu_parser_|dovi_rpu' "$ffmpeg" 2>/dev/null; then
    echo "ok $abi/libffmpeg.so: Dolby Vision RPU parser"
  else
    echo "ERROR: $abi/libffmpeg.so lacks Dolby Vision RPU parser" >&2
    fail=1
  fi
}

echo "==> verify Android MPV native (Vulkan + AV3A + DoVi; no assets/jni duplicate)"
check_abi arm64-v8a
check_abi armeabi-v7a
[[ "$fail" == 0 ]] || exit 1
echo "==> ok: Android MPV Vulkan + AV3A + DoVi checks passed"
