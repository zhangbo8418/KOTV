#!/usr/bin/env bash
# 页内原生 MPV 完整准备：拉取 libmpv 套件 + 编译 libvulkan stub + libkotv_dl。
# 套件只进 jniLibs（System.loadLibrary）；assets 仅保留 libvulkan stub（老机链接用）。
# 勿再把整套 .so 同时打进 assets 与 lib/（APK 会多约 80MB+）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
chmod +x "$ROOT/scripts/fetch-android-mpv-libs.sh" \
  "$ROOT/scripts/build-android-libvulkan-stub.sh" \
  "$ROOT/scripts/build-android-kotv-dl.sh"

echo "==> prepare Android MPV native (libmpv → jniLibs; vulkan stub → assets only)"
"$ROOT/scripts/fetch-android-mpv-libs.sh"

# webhtv 自带的 libc++ 与 libmpv 配套（含 __from_chars_floating_point）。
# 勿用本机 NDK28 覆盖：缺该符号 → dlopen(libmpv) 失败；NDK29 也不用（无法 exec 外部二进制）。
# 只需把 staging(assets) 里的 webhtv libc++ 同步进 jniLibs，避免 fvp 旧副本抢先加载。
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

# FFmpeg/libmpv 进 jniLibs：统一 System.loadLibrary（含 API25 / Android 15+）。
# 旧方案 assets 解压 + System.load(绝对路径) 在新系统易崩，且与 jniLibs 双份打包。
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
  # kotv_dl 由 build-android-kotv-dl 已写入 jniLibs
  echo "  ok $abi: staging assets → jniLibs"
}

# assets 只留 Vulkan stub（+ README）；其余 .so 已在 jniLibs，删掉避免 APK 重复。
strip_assets_keep_vulkan_stub() {
  local abi="$1"
  local base="$ROOT/flutter/android/app/src/main/assets/mpv-libs/$abi"
  local f name
  [[ -d "$base" ]] || return 0
  for f in "$base"/*; do
    [[ -f "$f" ]] || continue
    name="$(basename "$f")"
    if [[ "$name" == "libvulkan.so" ]]; then
      continue
    fi
    rm -f "$f"
  done
  echo "  ok $abi: assets keep libvulkan.so stub only"
}

sync_mpv_to_jni arm64-v8a
sync_mpv_to_jni armeabi-v7a
strip_assets_keep_vulkan_stub arm64-v8a
strip_assets_keep_vulkan_stub armeabi-v7a

verify_abi() {
  local abi="$1"
  local base="$ROOT/flutter/android/app/src/main/assets/mpv-libs/$abi"
  local jni="$ROOT/flutter/android/app/src/main/jniLibs/$abi"
  local missing=0
  local lib
  if [[ ! -s "$base/libvulkan.so" ]]; then
    echo "ERROR: missing assets/mpv-libs/$abi/libvulkan.so (stub)" >&2
    missing=1
  fi
  # 套件不得再留在 assets（会与 lib/ 重复进 APK）。
  for lib in libmpv.so libplayer.so libmvcodec.so libc++_shared.so libkotv_dl.so; do
    if [[ -s "$base/$lib" ]]; then
      echo "ERROR: assets/mpv-libs/$abi/$lib must not exist (duplicate of jniLibs)" >&2
      missing=1
    fi
  done
  # stub 不得进 jniLibs。
  if [[ -s "$jni/libvulkan.so" ]]; then
    echo "WARN: removing jniLibs/$abi/libvulkan.so (must not ship stub in APK lib/)" >&2
    rm -f "$jni/libvulkan.so"
  fi
  for lib in libmpv.so libplayer.so libmvcodec.so libmvutil.so libmwresample.so \
    libmwscale.so libmvformat.so libmvfilter.so libmvdevice.so libkotv_dl.so libc++_shared.so; do
    if [[ ! -s "$jni/$lib" ]]; then
      echo "ERROR: missing jniLibs/$abi/$lib" >&2
      missing=1
    fi
  done
  if [[ "$missing" != 0 ]]; then
    exit 1
  fi
  echo "  ok $abi: suite in jniLibs; vulkan stub in assets only"
}

verify_abi arm64-v8a
verify_abi armeabi-v7a
chmod +x "$ROOT/scripts/verify-android-mpv-libs.sh"
"$ROOT/scripts/verify-android-mpv-libs.sh"
echo "==> Android MPV native prepare done"
