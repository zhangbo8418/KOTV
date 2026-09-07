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

# webhtv 自带的 libc++ 与 libmpv 配套（含 __from_chars_floating_point）。
# 勿用本机 NDK28 覆盖：缺该符号 → dlopen(libmpv) 失败；NDK29 也不用（无法 exec 外部二进制）。
# 只需把 assets 里的 webhtv libc++ 同步进 jniLibs，避免 fvp 旧副本抢先加载。
sync_webhtv_libcxx_to_jni() {
  local abi="$1"
  local dest_asset="$ROOT/flutter/android/app/src/main/assets/mpv-libs/$abi/libc++_shared.so"
  local dest_jni="$ROOT/flutter/android/app/src/main/jniLibs/$abi/libc++_shared.so"
  mkdir -p "$(dirname "$dest_jni")"
  if [[ ! -s "$dest_asset" ]]; then
    echo "ERROR: missing $dest_asset (run fetch-android-mpv-libs first)" >&2
    return 1
  fi
  if ! grep -a -q 'from_chars_floating' "$dest_asset" 2>/dev/null; then
    echo "ERROR: $dest_asset missing from_chars_floating (corrupt/overwritten?). Re-fetch webhtv libc++." >&2
    return 1
  fi
  cp -f "$dest_asset" "$dest_jni"
  echo "  ok $abi: webhtv libc++_shared.so → jniLibs ($(wc -c <"$dest_asset" | tr -d ' ') bytes)"
}

for abi in arm64-v8a armeabi-v7a; do
  echo "==> native stubs: $abi"
  sync_webhtv_libcxx_to_jni "$abi"
  "$ROOT/scripts/build-android-libvulkan-stub.sh" "$abi"
  "$ROOT/scripts/build-android-kotv-dl.sh" "$abi"
done

# FFmpeg/libmpv 必须进 jniLibs：Android 15/16 上 System.load(绝对路径) 易在
# call_constructors 崩（tombstone 路径为 app_mpv-libs/…）。APK 内 loadLibrary 更稳。
sync_mpv_to_jni() {
  local abi="$1"
  local base="$ROOT/flutter/android/app/src/main/assets/mpv-libs/$abi"
  local jni="$ROOT/flutter/android/app/src/main/jniLibs/$abi"
  mkdir -p "$jni"
  local lib
  for lib in libc++_shared.so libmvutil.so libmwresample.so libmwscale.so \
    libmvcodec.so libmvformat.so libmvfilter.so libmvdevice.so \
    libmpv.so libplayer.so; do
    if [[ -s "$base/$lib" ]]; then
      cp -f "$base/$lib" "$jni/$lib"
    fi
  done
  echo "  ok $abi: assets mpv suite → jniLibs"
}

sync_mpv_to_jni arm64-v8a
sync_mpv_to_jni armeabi-v7a

verify_abi() {
  local abi="$1"
  local base="$ROOT/flutter/android/app/src/main/assets/mpv-libs/$abi"
  local jni="$ROOT/flutter/android/app/src/main/jniLibs/$abi"
  local missing=0
  local lib
  for lib in libmpv.so libplayer.so libmvcodec.so libc++_shared.so libvulkan.so libkotv_dl.so; do
    if [[ ! -s "$base/$lib" ]]; then
      echo "ERROR: missing assets/mpv-libs/$abi/$lib" >&2
      missing=1
    fi
  done
  # stub 只在 assets；jniLibs 有 libvulkan.so 会抢系统 Vulkan。
  if [[ -s "$jni/libvulkan.so" ]]; then
    echo "WARN: removing jniLibs/$abi/libvulkan.so (must not ship stub in APK lib/)" >&2
    rm -f "$jni/libvulkan.so"
  fi
  for lib in libmpv.so libplayer.so libmvcodec.so libmvutil.so libkotv_dl.so libc++_shared.so; do
    if [[ ! -s "$jni/$lib" ]]; then
      echo "ERROR: missing jniLibs/$abi/$lib" >&2
      missing=1
    fi
  done
  if [[ "$missing" != 0 ]]; then
    exit 1
  fi
  echo "  ok $abi: mpv + vulkan(stub in assets) + kotv_dl ready"
}

verify_abi arm64-v8a
verify_abi armeabi-v7a
chmod +x "$ROOT/scripts/verify-android-mpv-libs.sh"
"$ROOT/scripts/verify-android-mpv-libs.sh"
echo "==> Android MPV native prepare done"
