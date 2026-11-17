#!/usr/bin/env bash
# 页内原生 MPV：源码套件 → jniLibs；编 libvulkan stub + libkotv_dl；assets 仅留 stub。
# 勿把整套 .so 同时打进 assets 与 lib/（APK 会多约 80MB+）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/android-mpv-lib-names.sh
source "$ROOT/scripts/android-mpv-lib-names.sh"

ASSET="$ROOT/flutter/android/app/src/main/assets/mpv-libs"
JNI_ROOT="$ROOT/flutter/android/app/src/main/jniLibs"

chmod +x "$ROOT/scripts/build-android-mpv-from-source.sh" \
  "$ROOT/scripts/build-android-libvulkan-stub.sh" \
  "$ROOT/scripts/build-android-kotv-dl.sh" \
  "$ROOT/scripts/verify-android-mpv-libs.sh"

echo "==> prepare Android MPV native (source suite → jniLibs; vulkan stub → assets)"
if [[ "${KOTV_SKIP_ANDROID_MPV_SOURCE:-}" == "1" ]]; then
  echo "ok skip Android MPV source rebuild (KOTV_SKIP_ANDROID_MPV_SOURCE=1)"
else
  "$ROOT/scripts/build-android-mpv-from-source.sh"
fi

# 构建产出的 libc++ 与 libmpv 配套（含 from_chars）。勿用本机 NDK 另拷一份覆盖。
ensure_libcxx() {
  local abi="$1"
  local src="$ASSET/$abi/libc++_shared.so"
  local dest="$JNI_ROOT/$abi/libc++_shared.so"
  mkdir -p "$(dirname "$dest")"
  if [[ -s "$dest" ]] && kotv_android_libcxx_has_from_chars "$dest"; then
    echo "  ok $abi: libc++_shared.so in jniLibs ($(wc -c <"$dest" | tr -d ' ') bytes)"
    return 0
  fi
  if [[ ! -s "$src" ]]; then
    echo "ERROR: missing $src (and jniLibs has no valid libc++; re-run source build)" >&2
    return 1
  fi
  if ! kotv_android_libcxx_has_from_chars "$src"; then
    echo "ERROR: $src missing from_chars_floating; re-run source build" >&2
    return 1
  fi
  cp -f "$src" "$dest"
  echo "  ok $abi: libc++_shared.so → jniLibs ($(wc -c <"$src" | tr -d ' ') bytes)"
}

sync_suite_to_jni() {
  local abi="$1"
  local base="$ASSET/$abi"
  local jni="$JNI_ROOT/$abi"
  mkdir -p "$jni"
  kotv_android_mpv_purge_legacy "$jni"
  kotv_android_mpv_purge_legacy "$base"
  # 缓存命中后再跑 prepare 时 assets 已 strip，套件只在 jniLibs。
  if kotv_android_mpv_has_suite "$ASSET" "$abi"; then
    kotv_android_mpv_copy_suite "$base" "$jni" 1
  elif ! kotv_android_mpv_has_suite "$JNI_ROOT" "$abi"; then
    echo "ERROR: no MPV suite in assets or jniLibs for $abi" >&2
    return 1
  fi
  echo "  ok $abi: suite in jniLibs"
}

strip_assets_keep_vulkan() {
  local abi="$1"
  local base="$ASSET/$abi"
  local f name
  [[ -d "$base" ]] || return 0
  for f in "$base"/*; do
    [[ -f "$f" ]] || continue
    name="$(basename "$f")"
    [[ "$name" == "libvulkan.so" ]] && continue
    rm -f "$f"
  done
  echo "  ok $abi: assets keep libvulkan.so stub only"
}

PREPARE_ABIS=("${KOTV_ANDROID_MPV_ABIS[@]}")
if [[ -n "${KOTV_ANDROID_MPV_VERIFY_ABIS:-}" ]]; then
  # shellcheck disable=SC2206
  PREPARE_ABIS=(${KOTV_ANDROID_MPV_VERIFY_ABIS})
fi
for abi in "${PREPARE_ABIS[@]}"; do
  echo "==> native: $abi"
  ensure_libcxx "$abi"
  "$ROOT/scripts/build-android-libvulkan-stub.sh" "$abi"
  "$ROOT/scripts/build-android-kotv-dl.sh" "$abi"
  sync_suite_to_jni "$abi"
  strip_assets_keep_vulkan "$abi"
  if [[ -s "$JNI_ROOT/$abi/libvulkan.so" ]]; then
    echo "WARN: removing jniLibs/$abi/libvulkan.so (stub must not ship in APK lib/)" >&2
    rm -f "$JNI_ROOT/$abi/libvulkan.so"
  fi
done

"$ROOT/scripts/verify-android-mpv-libs.sh"
echo "==> Android MPV native prepare done"
