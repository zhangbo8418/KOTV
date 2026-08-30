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

# webhtv 的 libmpv 用较新 NDK 编，自带 libc++ 可能缺 __from_chars_floating_point。
# 用本机/CI 的 NDK libc++_shared 覆盖，并放进 jniLibs，避免 fvp 的旧 libc++ 抢先加载。
overlay_ndk_libcxx() {
  local abi="$1" triple="" ndk src dest_asset dest_jni
  dest_asset="$ROOT/flutter/android/app/src/main/assets/mpv-libs/$abi/libc++_shared.so"
  dest_jni="$ROOT/flutter/android/app/src/main/jniLibs/$abi/libc++_shared.so"
  mkdir -p "$(dirname "$dest_asset")" "$(dirname "$dest_jni")"
  ndk="${ANDROID_NDK_HOME:-${ANDROID_NDK:-}}"
  if [[ -z "$ndk" || ! -d "$ndk" ]]; then
    if [[ -n "${ANDROID_HOME:-}" ]]; then
      ndk="$(ls -d "$ANDROID_HOME"/ndk/* 2>/dev/null | sort -V | tail -1 || true)"
    fi
  fi
  if [[ -z "$ndk" || ! -d "$ndk" ]]; then
    ndk="$(ls -d "$HOME"/Library/Android/sdk/ndk/* 2>/dev/null | sort -V | tail -1 || true)"
  fi
  case "$abi" in
    arm64-v8a) triple=aarch64-linux-android ;;
    armeabi-v7a) triple=arm-linux-androideabi ;;
    *) echo "ERROR: skip libc++ overlay for $abi" >&2; return 1 ;;
  esac
  src="$(ls "$ndk"/toolchains/llvm/prebuilt/*/sysroot/usr/lib/"$triple"/libc++_shared.so 2>/dev/null | head -1 || true)"
  if [[ ! -f "$src" ]]; then
    src="$(ls "$ndk"/toolchains/llvm/prebuilt/*/sysroot/usr/lib/"$triple"/*/libc++_shared.so 2>/dev/null | tail -1 || true)"
  fi
  if [[ ! -f "$src" ]]; then
    src="$(ls "$ndk"/sources/cxx-stl/llvm-libc++/libs/"$abi"/libc++_shared.so 2>/dev/null | head -1 || true)"
  fi
  if [[ -f "$src" ]]; then
    cp -f "$src" "$dest_asset"
    cp -f "$src" "$dest_jni"
    echo "  ok $abi: NDK libc++_shared.so → assets + jniLibs ($(wc -c <"$src" | tr -d ' ') bytes)"
    return 0
  fi
  # 无 NDK 时至少把 webhtv 的 libc++ 放进 jniLibs，避免 fvp 旧副本抢先加载。
  if [[ -f "$dest_asset" ]]; then
    cp -f "$dest_asset" "$dest_jni"
    echo "  WARN $abi: NDK libc++ missing, copied assets libc++_shared.so → jniLibs" >&2
    return 0
  fi
  echo "ERROR: missing libc++_shared.so for $abi (NDK + assets)" >&2
  return 1
}

for abi in arm64-v8a armeabi-v7a; do
  echo "==> native stubs: $abi"
  overlay_ndk_libcxx "$abi"
  "$ROOT/scripts/build-android-libvulkan-stub.sh" "$abi"
  "$ROOT/scripts/build-android-kotv-dl.sh" "$abi"
done

verify_abi() {
  local abi="$1"
  local base="$ROOT/flutter/android/app/src/main/assets/mpv-libs/$abi"
  local jni="$ROOT/flutter/android/app/src/main/jniLibs/$abi"
  local missing=0
  for lib in libmpv.so libplayer.so libc++_shared.so libvulkan.so libkotv_dl.so; do
    if [[ ! -s "$base/$lib" ]]; then
      echo "ERROR: missing assets/mpv-libs/$abi/$lib" >&2
      missing=1
    fi
  done
  for lib in libvulkan.so libkotv_dl.so libc++_shared.so; do
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
