#!/usr/bin/env bash
# 将 libmpv 打进桌面应用包，位置与 fvp/mdk 相同（不进 runtime、不单独建 libmpv/ 目录）。
#   Windows：与 kotv.exe / mdk.dll 同目录
#   Linux：bundle/lib/（与 libmdk.so 相同，$ORIGIN/lib）
#   macOS：Contents/Frameworks/（与 mdk.xcframework 相同）
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

strip_runtime_libmpv() {
  rm -rf "$DEST/libmpv" "$DEST/runtime/libmpv" \
    "$DEST/Contents/Resources/runtime/libmpv" 2>/dev/null || true
}

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
    strip_runtime_libmpv
    echo "bundled macOS Frameworks/libmpv.dylib"
    ;;
  Linux)
    MPV="$ROOT/flutter/assets/mpv-libs/linux/libmpv.so.2"
    [[ -f "$MPV" ]] || { echo "ERROR: missing $MPV" >&2; exit 1; }
    mkdir -p "$DEST/lib"
    cp -f "$MPV" "$DEST/lib/libmpv.so.2"
    strip_runtime_libmpv
    echo "bundled linux lib/libmpv.so.2"
    ;;
  MINGW*|MSYS*|CYGWIN*)
    SRC="$ROOT/flutter/assets/mpv-libs/windows"
    [[ -f "$SRC/mpv-2.dll" || -f "$SRC/libmpv-2.dll" ]] || {
      echo "ERROR: missing windows libmpv dll" >&2
      exit 1
    }
    mkdir -p "$DEST"
    # 与 mdk.dll 同目录；已有的 Flutter/fvp DLL 不覆盖。
    if [[ -d "$SRC" ]]; then
      while IFS= read -r -d '' f; do
        base="$(basename "$f")"
        case "$base" in
          mpv-2.dll|libmpv-2.dll) cp -f "$f" "$DEST/$base" ;;
          *) [[ -e "$DEST/$base" ]] || cp -f "$f" "$DEST/$base" ;;
        esac
      done < <(find "$SRC" -maxdepth 1 -type f \( -iname '*.dll' -o -iname '*.pdb' \) -print0)
    fi
    if [[ -f "$SRC/mpv-2.dll" ]]; then
      cp -f "$SRC/mpv-2.dll" "$DEST/mpv-2.dll"
    elif [[ -f "$SRC/libmpv-2.dll" ]]; then
      cp -f "$SRC/libmpv-2.dll" "$DEST/mpv-2.dll"
    fi
    strip_runtime_libmpv
    [[ -f "$DEST/mpv-2.dll" || -f "$DEST/libmpv-2.dll" ]] || {
      echo "ERROR: mpv-2.dll not next to exe" >&2
      exit 1
    }
    staged="$(find "$SRC" -maxdepth 1 -type f -iname '*.dll' | wc -l | tr -d ' ')"
    echo "bundled windows mpv-2.dll next to exe (assets dlls=$staged)"
    find "$SRC" -maxdepth 1 -type f -iname '*.dll' -printf '  asset %f\n' 2>/dev/null \
      || find "$SRC" -maxdepth 1 -type f -iname '*.dll' | sed 's|.*/||;s|^|  asset |'
    ;;
  *)
    echo "skip bundle-app-libmpv on $(uname -s)" >&2
    ;;
esac
