#!/usr/bin/env bash
# 页内原生 MPV 完整准备：拉取 libmpv 套件 + 编译 libvulkan stub + libkotv_dl。
# 产物进 assets/mpv-libs/{abi}/ 与 jniLibs/{abi}/（APK 打包必需）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
chmod +x "$ROOT/scripts/fetch-android-mpv-libs.sh" \
  "$ROOT/scripts/build-android-libvulkan-stub.sh" \
  "$ROOT/scripts/build-android-kotv-dl.sh"

echo "==> prepare Android MPV native (libmpv + Vulkan stub + kotv_dl)"
"$ROOT/scripts/fetch-android-mpv-libs.sh"

for abi in arm64-v8a armeabi-v7a; do
  echo "==> native stubs: $abi"
  "$ROOT/scripts/build-android-libvulkan-stub.sh" "$abi"
  "$ROOT/scripts/build-android-kotv-dl.sh" "$abi"
done

verify_abi() {
  local abi="$1"
  local base="$ROOT/flutter/android/app/src/main/assets/mpv-libs/$abi"
  local jni="$ROOT/flutter/android/app/src/main/jniLibs/$abi"
  local missing=0
  for lib in libmpv.so libplayer.so libvulkan.so libkotv_dl.so; do
    if [[ ! -s "$base/$lib" ]]; then
      echo "ERROR: missing assets/mpv-libs/$abi/$lib" >&2
      missing=1
    fi
  done
  for lib in libvulkan.so libkotv_dl.so; do
    if [[ ! -s "$jni/$lib" ]]; then
      echo "ERROR: missing jniLibs/$abi/$lib" >&2
      missing=1
    fi
  done
  if [[ "$missing" != 0 ]]; then
    exit 1
  fi
  echo "  ok $abi: mpv + vulkan + kotv_dl ready"
}

verify_abi arm64-v8a
verify_abi armeabi-v7a
chmod +x "$ROOT/scripts/verify-android-mpv-libs.sh"
"$ROOT/scripts/verify-android-mpv-libs.sh"
echo "==> Android MPV native prepare done"
