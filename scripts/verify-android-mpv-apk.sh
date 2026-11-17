#!/usr/bin/env bash
# 校验 APK：MPV 套件只在 lib/<abi>/；Vulkan stub 只在 assets/mpv-libs（按包内实际 ABI）。
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
    "assets/mpv-libs/${abi}/libvulkan.so"
    "lib/${abi}/libmpv.so"
    "lib/${abi}/libplayer.so"
    "lib/${abi}/libffmpeg.so"
    "lib/${abi}/libkotv_dl.so"
    "lib/${abi}/libc++_shared.so"
  )
done <<<"$abis"

if [[ "${#need[@]}" -eq 0 ]]; then
  echo "ERROR: APK has no arm64-v8a/armeabi-v7a libs" >&2
  exit 1
fi

missing=0
for p in "${need[@]}"; do
  if ! grep -qxF "$p" <<<"$listing"; then
    echo "MISSING in APK: $p" >&2
    missing=1
  fi
done
if [[ "$missing" != 0 ]]; then
  exit 1
fi

foreign="$(printf '%s\n' "$listing" | awk -F/ -v have="$(printf '%s' "$abis" | tr '\n' ' ')" '
  $1=="assets" && $2=="mpv-libs" && $3!="" {
    abi=$3
    if (index(" " have " ", " " abi " ")==0) print
  }
')"
if [[ -n "$foreign" ]]; then
  echo "ERROR: APK contains mpv-libs for an ABI that is not in lib/:" >&2
  printf '%s\n' "$foreign" >&2
  exit 1
fi

if grep -qxF "assets/libmitv.so" <<<"$listing"; then
  if ! grep -qxF "armeabi-v7a" <<<"$abis"; then
    echo "ERROR: assets/libmitv.so is 32-bit and must not ship in an APK without armeabi-v7a" >&2
    exit 1
  fi
elif grep -qxF "armeabi-v7a" <<<"$abis"; then
  echo "ERROR: armeabi-v7a APK missing assets/libmitv.so" >&2
  exit 1
fi

while IFS= read -r abi; do
  [[ -n "$abi" ]] || continue
  case "$abi" in arm64-v8a|armeabi-v7a) ;; *) continue ;; esac
  # stub 不得出现在 lib/<abi>/。
  bad="lib/${abi}/libvulkan.so"
  if grep -qxF "$bad" <<<"$listing"; then
    echo "ERROR: APK must not contain $bad (stub steals system Vulkan)" >&2
    exit 1
  fi
  # 套件不得再出现在 assets（与 lib/ 重复）。
  for dup in libmpv.so libplayer.so libffmpeg.so libc++_shared.so libkotv_dl.so; do
    p="assets/mpv-libs/${abi}/${dup}"
    if grep -qxF "$p" <<<"$listing"; then
      echo "ERROR: APK must not contain $p (duplicate of lib/${abi}/)" >&2
      exit 1
    fi
  done
  # 旧 webhtv 拆库不得再进 APK。
  for legacy in libmvcodec.so libmvutil.so libmwresample.so libmwscale.so libmvformat.so libmvfilter.so libmvdevice.so; do
    p="lib/${abi}/${legacy}"
    if grep -qxF "$p" <<<"$listing"; then
      echo "ERROR: APK must not contain legacy split $p (use libffmpeg.so)" >&2
      exit 1
    fi
  done
done <<<"$abis"

echo "ok: APK MPV suite in lib/ only; Vulkan stub in assets only (abis: $(echo "$abis" | tr '\n' ' '))"
unzip -l "$APK" | awk '/mpv-libs|libvulkan|libkotv_dl|libmpv\.so|libplayer\.so/ {print $1, $4}' | head -30
