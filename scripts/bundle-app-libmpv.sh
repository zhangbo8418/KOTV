#!/usr/bin/env bash
# 将 libmpv 打进桌面应用包，位置与 fvp/mdk 相同（不进 runtime、不单独建 libmpv/ 目录）。
#   Windows：与 kotv.exe / mdk.dll 同目录
#   Linux：bundle/lib/（与 libmdk.so 相同，$ORIGIN/lib）
#   macOS：Contents/Frameworks/（与 mdk.xcframework 相同）+ 非系统 dylib 依赖
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

# macOS：把 libmpv 及其 Homebrew/前缀依赖收进 Frameworks，并改成 @rpath。
# 否则发行包在无 Homebrew 的机器上会 CREATE_FAILED（缺 _pl_* / libplacebo）。
kotv_macos_is_system_dylib() {
  case "$1" in
    /System/*|/usr/lib/*|/usr/lib/swift/*) return 0 ;;
    @rpath/*|@loader_path/*|@executable_path/*) return 0 ;;
  esac
  return 1
}

kotv_macos_bundle_dylib_deps() {
  local fw="$1"
  local root_lib="$2"
  local -a queue=()
  local lib dep base dest_lib old_id
  [[ -f "$root_lib" ]] || return 1
  command -v otool >/dev/null || return 1
  command -v install_name_tool >/dev/null || return 1

  install_name_tool -id "@rpath/$(basename "$root_lib")" "$root_lib" 2>/dev/null || true
  install_name_tool -add_rpath "@loader_path" "$root_lib" 2>/dev/null || true
  queue+=("$root_lib")

  while ((${#queue[@]} > 0)); do
    lib="${queue[0]}"
    queue=("${queue[@]:1}")
    while IFS= read -r dep; do
      [[ -n "$dep" ]] || continue
      kotv_macos_is_system_dylib "$dep" && continue
      [[ -f "$dep" ]] || {
        echo "WARN: missing dylib dep: $dep (from $(basename "$lib"))" >&2
        continue
      }
      base="$(basename "$dep")"
      # libplacebo.360.dylib → 也保留真实文件名
      dest_lib="$fw/$base"
      if [[ ! -f "$dest_lib" ]]; then
        cp -f "$dep" "$dest_lib"
        chmod u+w "$dest_lib" 2>/dev/null || true
        install_name_tool -id "@rpath/$base" "$dest_lib" 2>/dev/null || true
        install_name_tool -add_rpath "@loader_path" "$dest_lib" 2>/dev/null || true
        queue+=("$dest_lib")
        echo "  + Frameworks/$base"
      fi
      install_name_tool -change "$dep" "@rpath/$base" "$lib" 2>/dev/null || true
      # 兼容已是 @rpath/旧名 的情况
      old_id="$(otool -D "$dest_lib" 2>/dev/null | tail -1 | tr -d '[:space:]' || true)"
      if [[ -n "$old_id" && "$old_id" != "@rpath/$base" ]]; then
        install_name_tool -change "$old_id" "@rpath/$base" "$lib" 2>/dev/null || true
      fi
    done < <(otool -L "$lib" 2>/dev/null | awk 'NR>1 {print $1}')
  done
}

kotv_macos_verify_libmpv_self_contained() {
  local lib="$1"
  local bad=0
  local dep
  while IFS= read -r dep; do
    [[ -n "$dep" ]] || continue
    case "$dep" in
      /usr/local/*|/opt/homebrew/*|/Users/*)
        echo "ERROR: libmpv still links absolute path: $dep" >&2
        bad=1
        ;;
    esac
  done < <(otool -L "$lib" 2>/dev/null | awk 'NR>1 {print $1}')
  [[ "$bad" == 0 ]] || return 1
  # 无 Homebrew 路径时也应能 dlopen（依赖已在同目录 @rpath）
  if command -v python3 >/dev/null; then
    (cd "$(dirname "$lib")" && python3 - <<PY
import ctypes, os, sys
os.chdir(r"""$(dirname "$lib")""")
try:
    ctypes.CDLL(r"""$lib""")
except OSError as e:
    print("ERROR: dlopen Frameworks/libmpv.dylib failed:", e, file=sys.stderr)
    sys.exit(1)
print("ok dlopen Frameworks/libmpv.dylib")
PY
)
  fi
}

case "$(uname -s)" in
  Darwin)
    MPV="$ROOT/flutter/assets/mpv-libs/macos/libmpv.dylib"
    [[ -f "$MPV" ]] || { echo "ERROR: missing $MPV (fetch-desktop-mpv-libs failed)" >&2; exit 1; }
    FW="$DEST/Contents/Frameworks"
    mkdir -p "$FW"
    cp -f "$MPV" "$FW/libmpv.dylib"
    chmod u+w "$FW/libmpv.dylib" 2>/dev/null || true
    echo "==> bundle macOS libmpv + dylib deps into Frameworks"
    kotv_macos_bundle_dylib_deps "$FW" "$FW/libmpv.dylib"
    kotv_macos_verify_libmpv_self_contained "$FW/libmpv.dylib"
    strip_runtime_libmpv
    echo "bundled macOS Frameworks/libmpv.dylib (+ deps)"
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
        cp -f "$f" "$DEST/$base"
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
