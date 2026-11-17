#!/usr/bin/env bash
# 校验 APK：MPV 套件只在 lib/<abi>/；Vulkan stub 只在 assets/mpv-libs。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/android-mpv-lib-names.sh
source "$ROOT/scripts/android-mpv-lib-names.sh"

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
  need+=("assets/mpv-libs/${abi}/libvulkan.so")
  for so in "${KOTV_ANDROID_MPV_JNI_REQUIRED[@]}"; do
    need+=("lib/${abi}/${so}")
  done
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
[[ "$missing" == 0 ]] || exit 1

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
  if grep -qxF "lib/${abi}/libvulkan.so" <<<"$listing"; then
    echo "ERROR: APK must not contain lib/${abi}/libvulkan.so (stub steals system Vulkan)" >&2
    exit 1
  fi
  for so in "${KOTV_ANDROID_MPV_JNI_REQUIRED[@]}"; do
    if grep -qxF "assets/mpv-libs/${abi}/${so}" <<<"$listing"; then
      echo "ERROR: APK must not contain assets/mpv-libs/${abi}/${so} (duplicate of lib/)" >&2
      exit 1
    fi
  done
  for so in "${KOTV_ANDROID_MPV_LEGACY_PURGE[@]}"; do
    if grep -qxF "lib/${abi}/${so}" <<<"$listing"; then
      echo "ERROR: APK must not contain legacy lib/${abi}/${so}" >&2
      exit 1
    fi
  done
done <<<"$abis"

echo "ok: APK MPV suite in lib/ only; Vulkan stub in assets only (abis: $(echo "$abis" | tr '\n' ' '))"
unzip -l "$APK" | awk '/mpv-libs|libvulkan|libkotv_dl|libmpv\.so|libplayer\.so|libffmpeg\.so/ {print $1, $4}' | head -40
