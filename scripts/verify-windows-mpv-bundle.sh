#!/usr/bin/env bash
# 校验目录内 mpv-2.dll 的非系统依赖是否都在同目录（LoadLibrary winerr=126 门禁）。
# 用法: verify-windows-mpv-bundle.sh <dir-with-mpv-2.dll>
set -euo pipefail

DIR="${1:-}"
if [[ -z "$DIR" ]]; then
  echo "usage: $0 <dir>" >&2
  exit 1
fi

MPV="$DIR/mpv-2.dll"
[[ -f "$MPV" ]] || MPV="$DIR/libmpv-2.dll"
[[ -f "$MPV" ]] || { echo "ERROR: missing mpv-2.dll in $DIR" >&2; exit 1; }

_is_system_dll() {
  local lower
  lower="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    kernel32.dll|user32.dll|gdi32.dll|gdiplus.dll|advapi32.dll|shell32.dll|ole32.dll|oleaut32.dll| \
    ws2_32.dll|wsock32.dll|winmm.dll|dwmapi.dll|d3d9.dll|d3d11.dll|d3d12.dll|dxgi.dll|dxva2.dll| \
    opengl32.dll|ntdll.dll|msvcrt.dll|ucrtbase.dll|sechost.dll|rpcrt4.dll|comdlg32.dll|comctl32.dll| \
    imm32.dll|setupapi.dll|cfgmgr32.dll|version.dll|shlwapi.dll|crypt32.dll|bcrypt.dll|iphlpapi.dll| \
    dnsapi.dll|normaliz.dll|winhttp.dll|wininet.dll|avrt.dll|avicap32.dll|ncrypt.dll|secur32.dll| \
    uxtheme.dll|mfplat.dll|mf.dll|mfreadwrite.dll| \
    msvcp*.dll|vcruntime*.dll|concrt*.dll|api-ms-*|ext-ms-*|kernelbase.dll|userenv.dll| \
    powrprof.dll|wtsapi32.dll|dbghelp.dll|psapi.dll|oleacc.dll) return 0 ;;
  esac
  return 1
}

if ! command -v objdump >/dev/null 2>&1; then
  echo "WARN: objdump missing; only checking libplacebo + MinGW siblings" >&2
  missing=0
  if ! find "$DIR" -maxdepth 1 -iname 'libplacebo*.dll' | grep -q .; then
    for mingw in libgcc_s_seh-1.dll libstdc++-6.dll libwinpthread-1.dll; do
      [[ -f "$DIR/$mingw" ]] || { echo "ERROR: missing $mingw" >&2; missing=1; }
    done
  fi
  [[ "$missing" == 0 ]] || exit 1
  echo "ok $DIR (basic sibling check)"
  exit 0
fi

declare -A queued=()
declare -A seen=()
missing=()
queue=("$MPV")

_deps_of() {
  objdump -p "$1" 2>/dev/null | awk '/DLL Name:/{print $3}'
}

while ((${#queue[@]} > 0)); do
  dllpath="${queue[0]}"
  queue=("${queue[@]:1}")
  [[ -n "$dllpath" && -f "$dllpath" ]] || continue
  key="$(basename "$dllpath" | tr '[:upper:]' '[:lower:]')"
  [[ -n "${seen[$key]:-}" ]] && continue
  seen[$key]=1

  dep=""
  while IFS= read -r dep; do
    [[ -n "$dep" ]] || continue
    _is_system_dll "$dep" && continue
    dep_lc="$(printf '%s' "$dep" | tr '[:upper:]' '[:lower:]')"
    if [[ ! -f "$DIR/$dep" ]]; then
      missing+=("$dep")
      continue
    fi
    child="$DIR/$dep"
    ckey="$(basename "$child" | tr '[:upper:]' '[:lower:]')"
    [[ -n "${seen[$ckey]:-}" ]] && continue
    queue+=("$child")
  done < <(_deps_of "$dllpath")
done

if ((${#missing[@]} > 0)); then
  echo "ERROR: mpv bundle incomplete in $DIR (LoadLibrary winerr=126):" >&2
  printf '  missing %s\n' "${missing[@]}" | sort -u >&2
  echo "dlls present:" >&2
  find "$DIR" -maxdepth 1 -type f -iname '*.dll' -printf '  %f\n' 2>/dev/null \
    || find "$DIR" -maxdepth 1 -type f -iname '*.dll' | sed 's|.*/||;s|^|  |' >&2
  exit 1
fi

n="$(find "$DIR" -maxdepth 1 -type f -iname '*.dll' | wc -l | tr -d ' ')"
echo "ok windows mpv bundle: $n dlls, closure verified"
