#!/usr/bin/env bash
# 桌面 libmpv：一律源码编 FongMi mpv + AV3A FFmpeg（不拉 shinchiro / Ubuntu deb / brew bottle）。
# 产物：flutter/assets/mpv-libs/{windows,linux,macos}/
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSET="$ROOT/flutter/assets/mpv-libs"
mkdir -p "$ASSET"

export KOTV_BUILD_MPV_AV3A="${KOTV_BUILD_MPV_AV3A:-1}"

marker_ok() {
  local f="$1" min="${2:-100000}"
  [[ -f "$f" && "$(wc -c <"$f" | tr -d ' ')" -ge "$min" ]]
}

# shellcheck source=scripts/kotv-resolve-git-ref.sh
source "$ROOT/scripts/kotv-resolve-git-ref.sh"

# stamp 写入解析到的真实 SHA（跟 tip 时与构建一致，避免误命中旧缓存）。
kotv_mpv_src_stamp() {
  local mpv_repo="${KOTV_MPV_REPO:-https://github.com/FongMi/mpv.git}"
  local mpv_ref="${KOTV_MPV_REF:-fongmi}"
  local ff_repo="${KOTV_FFMPEG_REPO:-https://github.com/FongMi/FFmpeg.git}"
  local ff_ref="${KOTV_FFMPEG_REF:-release-9.1-fongmi}"
  local mpv ff pl
  mpv="$(kotv_resolve_git_ref "$mpv_repo" "$mpv_ref" "${KOTV_MPV_COMMIT:-}")"
  ff="$(kotv_resolve_git_ref "$ff_repo" "$ff_ref" "${KOTV_FFMPEG_COMMIT:-}")"
  pl="${KOTV_LIBPLACEBO_TAG:-v7.387.0}"
  printf 'mpv=%s ffmpeg=%s libplacebo=%s\n' "$mpv" "$ff" "$pl"
}

kotv_mpv_src_stamp_ok() {
  local stamp_file="$1"
  [[ -f "$stamp_file" ]] || return 1
  [[ "$(cat "$stamp_file")" == "$(kotv_mpv_src_stamp)" ]]
}

windows_siblings_ok() {
  [[ -f "$ASSET/windows/mpv-2.dll" ]] || return 1
  chmod +x "$ROOT/scripts/verify-windows-mpv-bundle.sh"
  "$ROOT/scripts/verify-windows-mpv-bundle.sh" "$ASSET/windows"
}

fetch_windows() {
  mkdir -p "$ASSET/windows"
  local out="$ASSET/windows/mpv-2.dll"
  local kind_file="$ASSET/windows/.kind"
  local src_stamp="$ASSET/windows/.kotv-mpv-src"
  local want_kind="av3a-dav1d-vulkan-d3d11-opengl-eglangle-osc-dovi-lcms-xxhash-v26"
  if [[ "${KOTV_WIN7:-}" == "1" || "${KOTV_MPV_WIN7:-}" == "1" ]]; then
    want_kind="av3a-dav1d-vulkan-d3d11-opengl-eglangle-osc-dovi-lcms-xxhash-win7-v28"
    export KOTV_MPV_WIN7=1
  fi
  if marker_ok "$out" 500000 && grep -aqE 'libarcdav3a|AV3A Audio Vivid' "$out" 2>/dev/null \
    && grep -aqE 'dovi_parse_unspec62_nalu|pl_hdr_metadata_from_dovi_rpu' "$out" 2>/dev/null \
    && grep -aqE 'dav1d_data_props|dav1d_get_picture|libdav1d' "$out" 2>/dev/null \
    && grep -aq 'd3d11-egl' "$out" 2>/dev/null \
    && [[ "$(cat "$kind_file" 2>/dev/null || true)" == "$want_kind" ]] \
    && kotv_mpv_src_stamp_ok "$src_stamp" \
    && windows_siblings_ok; then
    echo "ok windows/mpv-2.dll (cached AV3A + dovi + dav1d + sibling dlls, kind=$want_kind)"
    return
  fi
  echo "==> windows libmpv: source build with AV3A + libdovi + dav1d (kind=$want_kind)"
  "$ROOT/scripts/build-desktop-mpv-from-source.sh" windows
  echo "$want_kind" > "$kind_file"
  kotv_mpv_src_stamp > "$src_stamp"
}

fetch_linux() {
  mkdir -p "$ASSET/linux"
  local out="$ASSET/linux/libmpv.so.2"
  local src_stamp="$ASSET/linux/.kotv-mpv-src"
  if marker_ok "$out" 500000 && grep -aqE 'libarcdav3a|AV3A Audio Vivid' "$out" 2>/dev/null \
    && grep -aqE 'dovi_parse_unspec62_nalu|pl_hdr_metadata_from_dovi_rpu' "$out" 2>/dev/null \
    && grep -aqE 'dav1d_data_props|dav1d_get_picture|libdav1d' "$out" 2>/dev/null \
    && kotv_mpv_src_stamp_ok "$src_stamp"; then
    echo "ok linux/libmpv.so.2 (cached AV3A + libdovi + dav1d)"
    return
  fi
  echo "==> linux libmpv: source build with AV3A + libdovi + dav1d"
  "$ROOT/scripts/build-desktop-mpv-from-source.sh" linux
  kotv_mpv_src_stamp > "$src_stamp"
}

fetch_macos() {
  mkdir -p "$ASSET/macos"
  local out="$ASSET/macos/libmpv.dylib"
  local src_stamp="$ASSET/macos/.kotv-mpv-src"
  if marker_ok "$out" 500000 && grep -aqE 'libarcdav3a|AV3A Audio Vivid' "$out" 2>/dev/null \
    && grep -aqE 'dovi_parse_unspec62_nalu|pl_hdr_metadata_from_dovi_rpu' "$out" 2>/dev/null \
    && grep -aqE 'dav1d_data_props|dav1d_get_picture|libdav1d' "$out" 2>/dev/null \
    && kotv_mpv_src_stamp_ok "$src_stamp"; then
    echo "ok macOS/libmpv.dylib (cached AV3A + libdovi + dav1d)"
    return
  fi
  echo "==> macOS libmpv: source build with AV3A + libdovi + dav1d"
  if [[ "${KOTV_MPV_MACOS_ARCH:-$(uname -m)}" == "x86_64" && "$(uname -m)" == "arm64" ]]; then
    arch -x86_64 "$ROOT/scripts/build-desktop-mpv-from-source.sh" macos
  else
    "$ROOT/scripts/build-desktop-mpv-from-source.sh" macos
  fi
  kotv_mpv_src_stamp > "$src_stamp"
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

if [[ "${KOTV_WIN7:-}" == "1" ]]; then
  export KOTV_MPV_WIN7=1
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
KOTV_MPV_WIN7="${KOTV_MPV_WIN7:-${KOTV_WIN7:-0}}" \
"$ROOT/scripts/verify-desktop-mpv-libs.sh"
find "$ASSET" -mindepth 1 -maxdepth 1 -type d -empty -delete
du -sh "$ASSET"/* 2>/dev/null || true
echo "==> done"
