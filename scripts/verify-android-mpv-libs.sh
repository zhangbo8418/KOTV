#!/usr/bin/env bash
# 校验 Android MPV：套件在 jniLibs；Vulkan stub 仅在 assets（勿双份）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSET="$ROOT/flutter/android/app/src/main/assets/mpv-libs"
JNI_ROOT="$ROOT/flutter/android/app/src/main/jniLibs"
fail=0

check_abi() {
  local abi="$1"
  local asset_dir="$ASSET/$abi"
  local jni="$JNI_ROOT/$abi"
  local mpv="$jni/libmpv.so"
  local codec="$jni/libmvcodec.so"
  local vulkan_asset="$asset_dir/libvulkan.so"
  local vulkan_jni="$jni/libvulkan.so"
  local cxx_jni="$jni/libc++_shared.so"

  [[ -f "$mpv" ]] || { echo "ERROR: missing $mpv" >&2; fail=1; return; }
  [[ -f "$codec" ]] || { echo "ERROR: missing $codec" >&2; fail=1; return; }
  [[ -f "$cxx_jni" ]] || { echo "ERROR: missing $cxx_jni" >&2; fail=1; return; }
  [[ -f "$vulkan_asset" ]] || { echo "ERROR: missing $vulkan_asset (API25 stub in assets)" >&2; fail=1; return; }
  if [[ -f "$vulkan_jni" ]]; then
    echo "ERROR: $vulkan_jni must not exist (stub in jniLibs steals system Vulkan)" >&2
    fail=1
    return
  fi
  # 套件不得再出现在 assets（与 lib/ 重复打包）。
  local dup
  for dup in libmpv.so libplayer.so libmvcodec.so libc++_shared.so libkotv_dl.so; do
    if [[ -f "$asset_dir/$dup" ]]; then
      echo "ERROR: duplicate $asset_dir/$dup (must live only in jniLibs)" >&2
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

  if grep -aqE 'libarcdav3a|AV3A Audio Vivid|--enable-libarcdav3a' "$codec" 2>/dev/null; then
    echo "ok $abi/libmvcodec.so: AV3A (libarcdav3a)"
  else
    echo "ERROR: $abi/libmvcodec.so lacks AV3A (fetch webhtv mpv-libs)" >&2
    fail=1
  fi
}

echo "==> verify Android MPV native (Vulkan + AV3A; no assets/jni duplicate)"
check_abi arm64-v8a
check_abi armeabi-v7a
[[ "$fail" == 0 ]] || exit 1
echo "==> ok: Android MPV Vulkan + AV3A checks passed"
