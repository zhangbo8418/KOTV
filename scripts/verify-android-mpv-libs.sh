#!/usr/bin/env bash
# 校验 Android MPV 原生库：Vulkan libmpv + AV3A（libarcdav3a in libmvcodec，对齐 TV/webhtv）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSET="$ROOT/flutter/android/app/src/main/assets/mpv-libs"
fail=0

check_abi() {
  local abi="$1"
  local dir="$ASSET/$abi"
  local mpv="$dir/libmpv.so"
  local codec="$dir/libmvcodec.so"
  local vulkan_jni="$ROOT/flutter/android/app/src/main/jniLibs/$abi/libvulkan.so"
  local cxx="$dir/libc++_shared.so"
  local cxx_jni="$ROOT/flutter/android/app/src/main/jniLibs/$abi/libc++_shared.so"

  [[ -f "$mpv" ]] || { echo "ERROR: missing $mpv" >&2; fail=1; return; }
  [[ -f "$codec" ]] || { echo "ERROR: missing $codec" >&2; fail=1; return; }
  [[ -f "$cxx" ]] || { echo "ERROR: missing $cxx" >&2; fail=1; return; }
  [[ -f "$cxx_jni" ]] || { echo "ERROR: missing $cxx_jni" >&2; fail=1; return; }
  [[ -f "$vulkan_jni" ]] || { echo "ERROR: missing $vulkan_jni" >&2; fail=1; return; }

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

echo "==> verify Android MPV native (Vulkan + AV3A)"
check_abi arm64-v8a
check_abi armeabi-v7a
[[ "$fail" == 0 ]] || exit 1
echo "==> ok: Android MPV Vulkan + AV3A checks passed"
