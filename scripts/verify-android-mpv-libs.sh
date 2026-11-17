#!/usr/bin/env bash
# 校验 Android MPV：套件在 jniLibs；Vulkan stub 仅在 assets；业务标记齐全。
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
  local lib

  if [[ ! -s "$asset_dir/libvulkan.so" ]]; then
    echo "ERROR: missing $asset_dir/libvulkan.so (API25 stub)" >&2
    fail=1
    return
  fi
  if [[ -f "$jni/libvulkan.so" ]]; then
    echo "ERROR: $jni/libvulkan.so must not exist (stub steals system Vulkan)" >&2
    fail=1
    return
  fi
  for lib in "${KOTV_ANDROID_MPV_JNI_REQUIRED[@]}"; do
    if [[ ! -s "$jni/$lib" ]]; then
      echo "ERROR: missing $jni/$lib" >&2
      fail=1
    fi
    if [[ -f "$asset_dir/$lib" ]]; then
      echo "ERROR: duplicate $asset_dir/$lib (must live only in jniLibs)" >&2
      fail=1
    fi
  done
  for lib in "${KOTV_ANDROID_MPV_LEGACY_PURGE[@]}"; do
    if [[ -f "$jni/$lib" || -f "$asset_dir/$lib" ]]; then
      echo "ERROR: legacy $lib must be removed under $abi" >&2
      fail=1
    fi
  done
  if [[ "$fail" != 0 ]]; then
    return
  fi
  if ! kotv_android_libcxx_has_from_chars "$jni/libc++_shared.so"; then
    echo "ERROR: $abi/libc++_shared.so missing from_chars_floating" >&2
    fail=1
    return
  fi
  if ! kotv_android_mpv_check_markers "$abi" "$jni/libmpv.so" "$jni/libffmpeg.so"; then
    fail=1
    return
  fi
  echo "ok $abi: layout + markers"
}

echo "==> verify Android MPV native"
MPV_JAVA="$ROOT/flutter/android/app/src/main/java/is/xyz/mpv/MPVLib.java"
if ! kotv_android_mpv_check_jni_java_callbacks "$MPV_JAVA"; then
  fail=1
fi
# 可选：KOTV_ANDROID_MPV_VERIFY_ABIS="arm64-v8a" 只核指定 ABI（本地抽包验证）。
VERIFY_ABIS=("${KOTV_ANDROID_MPV_ABIS[@]}")
if [[ -n "${KOTV_ANDROID_MPV_VERIFY_ABIS:-}" ]]; then
  # shellcheck disable=SC2206
  VERIFY_ABIS=(${KOTV_ANDROID_MPV_VERIFY_ABIS})
fi
for abi in "${VERIFY_ABIS[@]}"; do
  check_abi "$abi"
done
[[ "$fail" == 0 ]] || exit 1
echo "==> ok: Android MPV native checks passed"
