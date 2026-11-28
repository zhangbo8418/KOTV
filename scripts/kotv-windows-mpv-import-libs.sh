#!/usr/bin/env bash
# 从 mpv-2.dll 生成导入库：MSVC → mpv.lib；MinGW → libmpv.dll.a。
# 发行包只带 libmpv-2.dll（见 flutter/windows/CMakeLists.txt），故导入库的
# LIBRARY 必须是 libmpv-2.dll，否则运行时会找 mpv-2.dll / mpv.dll 失败。
# 用法: kotv-windows-mpv-import-libs.sh [path/to/mpv-2.dll]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=kotv-win-build-env.sh
source "$ROOT/scripts/kotv-win-build-env.sh"
dll="${1:-$ROOT/flutter/assets/mpv-libs/windows/mpv-2.dll}"
[[ -f "$dll" ]] || { echo "usage: $0 <mpv-2.dll>" >&2; exit 1; }
dir="$(cd "$(dirname "$dll")" && pwd)"
dest_def="$dir/mpv-2.def"
# MSVC lib.exe：arm64 包必须 -machine:ARM64，写死 x64 会 LNK4272 +  unresolved mpv_*。
mpv_lib_machine="x64"
if kotv_windows_is_arm64; then
  mpv_lib_machine="ARM64"
fi

if command -v gendef >/dev/null 2>&1; then
  gendef - "$dll" >"$dest_def" 2>/dev/null || gendef "$dll" - >"$dest_def" 2>/dev/null || true
fi

# gendef 常写出 LIBRARY mpv-2.dll；与安装名 libmpv-2.dll 对齐。
if [[ -s "$dest_def" ]]; then
  if grep -qiE '^[[:space:]]*LIBRARY[[:space:]]' "$dest_def"; then
    sed -i.bak -E 's/^[[:space:]]*LIBRARY[[:space:]].*/LIBRARY libmpv-2.dll/' "$dest_def"
  else
    printf '%s\n%s\n' 'LIBRARY libmpv-2.dll' "$(cat "$dest_def")" >"$dest_def.tmp"
    mv "$dest_def.tmp" "$dest_def"
  fi
  rm -f "$dest_def.bak"
fi

if [[ -s "$dest_def" ]] && command -v dlltool >/dev/null 2>&1; then
  dlltool -d "$dest_def" -l "$dir/libmpv.dll.a" -D libmpv-2.dll \
    && echo "ok windows/libmpv.dll.a (dlltool, LIBRARY=libmpv-2.dll)"
fi

libexe=""
if command -v lib.exe >/dev/null 2>&1; then
  libexe="$(command -v lib.exe)"
elif [[ -n "${VSINSTALLDIR:-}" ]]; then
  libexe="$(find "${VSINSTALLDIR}/VC/Tools/MSVC" -name lib.exe 2>/dev/null | head -1 || true)"
fi
if [[ -s "$dest_def" && -n "$libexe" ]]; then
  # Git Bash/MSYS 会把 /nologo 误转成 C:\Program Files\Git\nologo → LNK1181。
  # 用 -nologo，并对其余 / 开关关闭路径转换；因此路径要先转成 D:/… 形式（否则 LNK1104）。
  win_def="$dest_def" win_out="$dir/mpv.lib"
  if command -v cygpath >/dev/null 2>&1; then
    win_def="$(cygpath -m "$dest_def")"
    win_out="$(cygpath -m "$dir/mpv.lib")"
  fi
  MSYS2_ARG_CONV_EXCL='*' "$libexe" -nologo "-machine:${mpv_lib_machine}" "-def:$win_def" "-out:$win_out" \
    && echo "ok windows/mpv.lib (MSVC import, machine=${mpv_lib_machine}, LIBRARY=libmpv-2.dll)"
fi

if [[ ! -f "$dir/mpv.lib" && ! -f "$dir/libmpv.dll.a" ]]; then
  echo "WARN: no import lib beside $dll (MSVC needs mpv.lib)" >&2
  exit 1
fi
