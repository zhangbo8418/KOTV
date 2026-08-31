#!/usr/bin/env bash
# 桌面 libmpv：一律源码编 FongMi mpv + AV3A FFmpeg（不拉 shinchiro / Ubuntu deb / brew bottle）。
# 产物：flutter/assets/mpv-libs/{windows,linux,macos}/
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSET="$ROOT/flutter/assets/mpv-libs"
mkdir -p "$ASSET/windows" "$ASSET/linux" "$ASSET/macos"

export KOTV_BUILD_MPV_AV3A="${KOTV_BUILD_MPV_AV3A:-1}"

marker_ok() {
  local f="$1" min="${2:-100000}"
  [[ -f "$f" && "$(wc -c <"$f" | tr -d ' ')" -ge "$min" ]]
}

windows_siblings_ok() {
  [[ -f "$ASSET/windows/mpv-2.dll" ]] || return 1
  chmod +x "$ROOT/scripts/verify-windows-mpv-bundle.sh"
  "$ROOT/scripts/verify-windows-mpv-bundle.sh" "$ASSET/windows"
}

fetch_windows() {
  local out="$ASSET/windows/mpv-2.dll"
  local kind_file="$ASSET/windows/.kind"
  if marker_ok "$out" 500000 && grep -aqE 'libarcdav3a|AV3A Audio Vivid' "$out" 2>/dev/null \
    && [[ "$(cat "$kind_file" 2>/dev/null || true)" == "av3a-win7-v5" ]] \
    && windows_siblings_ok; then
    echo "ok windows/mpv-2.dll (cached AV3A + sibling dlls)"
    return
  fi
  echo "==> windows libmpv: source build with AV3A (FongMi FFmpeg + MinGW)"
  "$ROOT/scripts/build-desktop-mpv-from-source.sh" windows
  echo av3a-win7-v5 > "$kind_file"
}

fetch_linux() {
  local out="$ASSET/linux/libmpv.so.2"
  if marker_ok "$out" 500000 && grep -aqE 'libarcdav3a|AV3A Audio Vivid' "$out" 2>/dev/null; then
    echo "ok linux/libmpv.so.2 (cached AV3A)"
    return
  fi
  echo "==> linux libmpv: source build with AV3A (FongMi FFmpeg + libarcdav3a)"
  "$ROOT/scripts/build-desktop-mpv-from-source.sh" linux
}

fetch_macos() {
  local out="$ASSET/macos/libmpv.dylib"
  if marker_ok "$out" 500000 && grep -aqE 'libarcdav3a|AV3A Audio Vivid' "$out" 2>/dev/null; then
    echo "ok macOS/libmpv.dylib (cached AV3A)"
    return
  fi
  echo "==> macOS libmpv: source build with AV3A (FongMi FFmpeg + libarcdav3a)"
  if [[ "${KOTV_MPV_MACOS_ARCH:-$(uname -m)}" == "x86_64" && "$(uname -m)" == "arm64" ]]; then
    arch -x86_64 "$ROOT/scripts/build-desktop-mpv-from-source.sh" macos
  else
    "$ROOT/scripts/build-desktop-mpv-from-source.sh" macos
  fi
}

run_fetch() {
  case "$1" in
    windows|win) fetch_windows ;;
    linux) fetch_linux ;;
    macos|darwin) fetch_macos ;;
    *) echo "unknown desktop plat: $1" >&2; exit 1 ;;
  esac
}

detect_desktop_plat() {
  case "$(uname -s 2>/dev/null)" in
    Linux*) echo linux ;;
    Darwin*) echo macos ;;
    MINGW*|MSYS*|CYGWIN*) echo windows ;;
    *)
      if [[ "${OS:-}" == "Windows_NT" ]]; then
        echo windows
      fi
      ;;
  esac
}

if [[ -z "${KOTV_FETCH_DESKTOP_PLAT:-}" ]]; then
  auto="$(detect_desktop_plat || true)"
  if [[ -n "$auto" ]]; then
    KOTV_FETCH_DESKTOP_PLAT="$auto"
    echo "==> auto KOTV_FETCH_DESKTOP_PLAT=$KOTV_FETCH_DESKTOP_PLAT"
  fi
fi

echo "==> fetch desktop libmpv (AV3A source) → $ASSET"
if [[ -n "${KOTV_FETCH_DESKTOP_PLAT:-}" ]]; then
  run_fetch "${KOTV_FETCH_DESKTOP_PLAT}"
else
  run_fetch windows
  run_fetch linux
  run_fetch macos
fi
KOTV_VERIFY_PLAT="${KOTV_VERIFY_PLAT:-${KOTV_FETCH_DESKTOP_PLAT:-}}" \
KOTV_EXPECT_MPV_AV3A="${KOTV_EXPECT_MPV_AV3A:-1}" \
"$ROOT/scripts/verify-desktop-mpv-libs.sh"
du -sh "$ASSET"/* 2>/dev/null || true
echo "==> done"
