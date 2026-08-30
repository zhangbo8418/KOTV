#!/usr/bin/env bash
# 把桌面 libmpv 装进 runtime/libmpv（页内原生 MPV；与 jre/python 一样随 runtime 走）。
# 用法: install-runtime-libmpv.sh [runtime-dir] [platform]
# platform 缺省：当前主机；可为 macos-arm64 / linux-x64 / windows-x64 等。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RT="${1:-$ROOT/runtime}"
PLAT="${2:-}"

detect_plat() {
  local os arch
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  case "$os" in
    darwin) [[ "$arch" == "arm64" ]] && echo "macos-arm64" || echo "macos-x64" ;;
    linux) [[ "$arch" == "aarch64" || "$arch" == "arm64" ]] && echo "linux-arm64" || echo "linux-x64" ;;
    mingw*|msys*|cygwin*) [[ "$arch" == "aarch64" || "$arch" == "arm64" ]] && echo "windows-arm64" || echo "windows-x64" ;;
    *)
      if [[ "${OS:-}" == "Windows_NT" ]]; then
        echo "windows-x64"
      else
        echo "unknown"
      fi
      ;;
  esac
}

[[ -n "$PLAT" ]] || PLAT="$(detect_plat)"
fetch_plat=""
case "$PLAT" in
  macos-*) fetch_plat=macos ;;
  linux-*) fetch_plat=linux ;;
  windows-*) fetch_plat=windows ;;
  macos|linux|windows) fetch_plat="$PLAT" ;;
  *) echo "ERROR: install-runtime-libmpv: unknown platform $PLAT" >&2; exit 1 ;;
esac

chmod +x "$ROOT/scripts/fetch-desktop-mpv-libs.sh"
KOTV_FETCH_DESKTOP_PLAT="$fetch_plat" "$ROOT/scripts/fetch-desktop-mpv-libs.sh"

ASSET="$ROOT/flutter/assets/mpv-libs"
DEST="$RT/libmpv"
mkdir -p "$DEST"

case "$fetch_plat" in
  macos)
    src="$ASSET/macos/libmpv.dylib"
    [[ -f "$src" ]] || { echo "ERROR: missing $src" >&2; exit 1; }
    cp -f "$src" "$DEST/libmpv.dylib"
    if command -v install_name_tool >/dev/null; then
      install_name_tool -id "@rpath/libmpv.dylib" "$DEST/libmpv.dylib" 2>/dev/null || true
    fi
    echo "runtime libmpv: $DEST/libmpv.dylib ($(wc -c <"$DEST/libmpv.dylib" | tr -d ' ') bytes)"
    ;;
  linux)
    src="$ASSET/linux/libmpv.so.2"
    [[ -f "$src" ]] || { echo "ERROR: missing $src" >&2; exit 1; }
    cp -f "$src" "$DEST/libmpv.so.2"
    echo "runtime libmpv: $DEST/libmpv.so.2 ($(wc -c <"$DEST/libmpv.so.2" | tr -d ' ') bytes)"
    ;;
  windows)
    if [[ -d "$ASSET/windows" ]]; then
      find "$ASSET/windows" -maxdepth 1 -type f \( -iname '*.dll' -o -iname '*.pdb' \) -exec cp -f {} "$DEST/" \;
    fi
    if [[ -f "$ASSET/windows/mpv-2.dll" ]]; then
      cp -f "$ASSET/windows/mpv-2.dll" "$DEST/mpv-2.dll"
    elif [[ -f "$ASSET/windows/libmpv-2.dll" ]]; then
      cp -f "$ASSET/windows/libmpv-2.dll" "$DEST/mpv-2.dll"
      cp -f "$ASSET/windows/libmpv-2.dll" "$DEST/libmpv-2.dll"
    fi
    [[ -f "$DEST/mpv-2.dll" || -f "$DEST/libmpv-2.dll" ]] || {
      echo "ERROR: missing windows libmpv dll" >&2
      exit 1
    }
    echo "runtime libmpv: $DEST (windows dlls)"
    ;;
esac
