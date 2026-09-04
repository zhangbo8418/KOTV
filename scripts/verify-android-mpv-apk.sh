#!/usr/bin/env bash
# 校验 APK 已打入页内 MPV + Vulkan stub（按包内实际 ABI，兼容单 ABI 分包）。
set -euo pipefail
APK="${1:-}"
if [[ -z "$APK" || ! -f "$APK" ]]; then
  echo "usage: $0 <path-to.apk>" >&2
  exit 1
fi
listing="$(unzip -l "$APK" | awk 'NR>3 {print $4}')"
abis="$(printf '%s\n' "$listing" | awk -F/ '/^lib\//{print $2}' | sort -u)"
if [[ -z "$abis" ]]; then
  echo "ERROR: no lib/<abi>/ entries in APK" >&2
  exit 1
fi

need=()
while IFS= read -r abi; do
  [[ -n "$abi" ]] || continue
  case "$abi" in
    arm64-v8a|armeabi-v7a) ;;
    *) continue ;;
  esac
  need+=(
    "assets/mpv-libs/${abi}/libmpv.so"
    "assets/mpv-libs/${abi}/libplayer.so"
    "assets/mpv-libs/${abi}/libvulkan.so"
    "assets/mpv-libs/${abi}/libkotv_dl.so"
    "lib/${abi}/libvulkan.so"
    "lib/${abi}/libkotv_dl.so"
  )
done <<<"$abis"

if [[ "${#need[@]}" -eq 0 ]]; then
  echo "ERROR: APK has no arm64-v8a/armeabi-v7a libs" >&2
  exit 1
fi

missing=0
for p in "${need[@]}"; do
  # 勿 printf|grep -q：命中时 grep 提前关管，pipefail 下 printf SIGPIPE 会误失败
  if ! grep -qxF "$p" <<<"$listing"; then
    echo "MISSING in APK: $p" >&2
    missing=1
  fi
done
if [[ "$missing" != 0 ]]; then
  exit 1
fi
echo "ok: APK contains bundled MPV + Vulkan native libs (abis: $(echo "$abis" | tr '\n' ' '))"
unzip -l "$APK" | awk '/mpv-libs|libvulkan|libkotv_dl|libmpv\.so|libplayer\.so/ {print $1, $4}' | head -20
