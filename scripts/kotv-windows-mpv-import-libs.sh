#!/usr/bin/env bash
# 从 mpv-2.dll 生成导入库：MSVC → mpv.lib；MinGW → libmpv.dll.a。
# 用法: kotv-windows-mpv-import-libs.sh [path/to/mpv-2.dll]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
dll="${1:-$ROOT/flutter/assets/mpv-libs/windows/mpv-2.dll}"
[[ -f "$dll" ]] || { echo "usage: $0 <mpv-2.dll>" >&2; exit 1; }
dir="$(cd "$(dirname "$dll")" && pwd)"
dest_def="$dir/mpv-2.def"

if command -v gendef >/dev/null 2>&1; then
  gendef - "$dll" >"$dest_def" 2>/dev/null || gendef "$dll" - >"$dest_def" 2>/dev/null || true
fi

if [[ -s "$dest_def" ]] && command -v dlltool >/dev/null 2>&1; then
  dlltool -d "$dest_def" -l "$dir/libmpv.dll.a" -D mpv-2.dll \
    && echo "ok windows/libmpv.dll.a (dlltool)"
fi

libexe=""
if command -v lib.exe >/dev/null 2>&1; then
  libexe="$(command -v lib.exe)"
elif [[ -n "${VSINSTALLDIR:-}" ]]; then
  libexe="$(find "${VSINSTALLDIR}/VC/Tools/MSVC" -name lib.exe 2>/dev/null | head -1 || true)"
fi
if [[ -s "$dest_def" && -n "$libexe" ]]; then
  "$libexe" /nologo /machine:x64 /def:"$dest_def" /out:"$dir/mpv.lib" \
    && echo "ok windows/mpv.lib (MSVC import)"
fi

if [[ ! -f "$dir/mpv.lib" && ! -f "$dir/libmpv.dll.a" ]]; then
  echo "WARN: no import lib beside $dll (MSVC needs mpv.lib)" >&2
  exit 1
fi
