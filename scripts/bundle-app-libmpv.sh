#!/usr/bin/env bash
# 将 libmpv 打进桌面应用包（页内原生 MPV P2）。
# 用法: bundle-app-libmpv.sh <KO影视.app | linux/win install dir>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:-}"
if [[ -z "$DEST" ]]; then
  echo "usage: $0 <app-bundle-or-install-dir>" >&2
  exit 1
fi
chmod +x "$ROOT/scripts/fetch-desktop-mpv-libs.sh"
"$ROOT/scripts/fetch-desktop-mpv-libs.sh"

case "$(uname -s)" in
  Darwin)
    MPV="$ROOT/flutter/assets/mpv-libs/macos/libmpv.dylib"
    if [[ ! -f "$MPV" ]]; then
      echo "WARNING: $MPV missing (brew install mpv)" >&2
      exit 0
    fi
    FW="$DEST/Contents/Frameworks"
    mkdir -p "$FW"
    cp -f "$MPV" "$FW/libmpv.dylib"
    if command -v install_name_tool >/dev/null; then
      install_name_tool -id "@rpath/libmpv.dylib" "$FW/libmpv.dylib" 2>/dev/null || true
    fi
    echo "bundled macOS Frameworks/libmpv.dylib"
    ;;
  Linux)
    MPV="$ROOT/flutter/assets/mpv-libs/linux/libmpv.so.2"
    if [[ ! -f "$MPV" ]]; then
      echo "WARNING: $MPV missing (apt install libmpv2)" >&2
      exit 0
    fi
    mkdir -p "$DEST/libmpv"
    cp -f "$MPV" "$DEST/libmpv/libmpv.so.2"
    echo "bundled linux libmpv/libmpv.so.2"
    ;;
  MINGW*|MSYS*|CYGWIN*)
    MPV="$ROOT/flutter/assets/mpv-libs/windows/mpv-2.dll"
    if [[ ! -f "$MPV" ]]; then
      echo "WARNING: $MPV missing — copy from mpv-winbuild-cmake" >&2
      exit 0
    fi
    mkdir -p "$DEST/libmpv"
    cp -f "$MPV" "$DEST/libmpv/mpv-2.dll"
    echo "bundled windows libmpv/mpv-2.dll"
    ;;
  *)
    echo "skip bundle-app-libmpv on $(uname -s)" >&2
    ;;
esac
