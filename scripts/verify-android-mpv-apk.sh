#!/usr/bin/env bash
# 校验 APK 已打入页内 MPV + Vulkan stub。
set -euo pipefail
APK="${1:-}"
if [[ -z "$APK" || ! -f "$APK" ]]; then
  echo "usage: $0 <path-to.apk>" >&2
  exit 1
fi
listing="$(unzip -l "$APK" | awk 'NR>3 {print $4}')"
need=(
  "assets/mpv-libs/arm64-v8a/libmpv.so"
  "assets/mpv-libs/arm64-v8a/libplayer.so"
  "assets/mpv-libs/arm64-v8a/libvulkan.so"
  "assets/mpv-libs/arm64-v8a/libkotv_dl.so"
  "lib/arm64-v8a/libvulkan.so"
  "lib/arm64-v8a/libkotv_dl.so"
)
# armv7 apk only has armeabi-v7a paths
if unzip -l "$APK" | grep -q 'lib/armeabi-v7a/'; then
  need+=(
    "assets/mpv-libs/armeabi-v7a/libmpv.so"
    "assets/mpv-libs/armeabi-v7a/libvulkan.so"
    "assets/mpv-libs/armeabi-v7a/libkotv_dl.so"
    "lib/armeabi-v7a/libvulkan.so"
    "lib/armeabi-v7a/libkotv_dl.so"
  )
fi
missing=0
for p in "${need[@]}"; do
  if ! printf '%s\n' "$listing" | grep -qx "$p"; then
    echo "MISSING in APK: $p" >&2
    missing=1
  fi
done
if [[ "$missing" != 0 ]]; then
  exit 1
fi
echo "ok: APK contains bundled MPV + Vulkan native libs"
unzip -l "$APK" | awk '/mpv-libs|libvulkan|libkotv_dl|libmpv\.so|libplayer\.so/ {print $1, $4}' | head -20
