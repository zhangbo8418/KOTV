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
    [[ -f "$MPV" ]] || { echo "ERROR: missing $MPV (fetch-desktop-mpv-libs failed)" >&2; exit 1; }
    FW="$DEST/Contents/Frameworks"
    mkdir -p "$FW"
    cp -f "$MPV" "$FW/libmpv.dylib"
    if command -v install_name_tool >/dev/null; then
      install_name_tool -id "@rpath/libmpv.dylib" "$FW/libmpv.dylib" 2>/dev/null || true
    fi
    echo "bundled macOS Frameworks/libmpv.dylib"
    mkdir -p "$DEST/Contents/Resources/runtime/libmpv"
    cp -f "$MPV" "$DEST/Contents/Resources/runtime/libmpv/libmpv.dylib"
    echo "bundled macOS runtime/libmpv/libmpv.dylib"
    ;;
  Linux)
    MPV="$ROOT/flutter/assets/mpv-libs/linux/libmpv.so.2"
    [[ -f "$MPV" ]] || { echo "ERROR: missing $MPV" >&2; exit 1; }
    mkdir -p "$DEST/libmpv"
    cp -f "$MPV" "$DEST/libmpv/libmpv.so.2"
    echo "bundled linux libmpv/libmpv.so.2"
    if [[ -d "$DEST/runtime" ]]; then
      mkdir -p "$DEST/runtime/libmpv"
      cp -f "$MPV" "$DEST/runtime/libmpv/libmpv.so.2"
      echo "bundled linux runtime/libmpv/libmpv.so.2"
    fi
    ;;
  MINGW*|MSYS*|CYGWIN*)
    SRC="$ROOT/flutter/assets/mpv-libs/windows"
    [[ -f "$SRC/mpv-2.dll" || -f "$SRC/libmpv-2.dll" ]] || {
      echo "ERROR: missing windows libmpv dll" >&2
      exit 1
    }
    copy_win_mpv_dlls() {
      local dest="$1"
      mkdir -p "$dest"
      find "$SRC" -maxdepth 1 -type f \( -iname '*.dll' -o -iname '*.pdb' \) -exec cp -f {} "$dest/" \;
      if [[ -f "$SRC/mpv-2.dll" ]]; then
        cp -f "$SRC/mpv-2.dll" "$dest/mpv-2.dll"
      elif [[ -f "$SRC/libmpv-2.dll" ]]; then
        cp -f "$SRC/libmpv-2.dll" "$dest/mpv-2.dll"
        cp -f "$SRC/libmpv-2.dll" "$dest/libmpv-2.dll"
      fi
    }
    copy_win_mpv_dlls "$DEST/libmpv"
    echo "bundled windows libmpv/*.dll"
    if [[ -d "$DEST/runtime" ]]; then
      copy_win_mpv_dlls "$DEST/runtime/libmpv"
      echo "bundled windows runtime/libmpv/*.dll"
    fi
    ;;
  *)
    echo "skip bundle-app-libmpv on $(uname -s)" >&2
    ;;
esac
