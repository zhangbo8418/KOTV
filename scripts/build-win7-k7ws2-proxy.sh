#!/usr/bin/env bash
# Build Win7 ws2_32 proxy (k7ws2.dll) next to the app and PE-patch imports.
# Usage: build-win7-k7ws2-proxy.sh <release-dir-with-exe-dlls>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="${1:?release dir}"
BUILD="${KOTV_MPV_BUILD_DIR:-$ROOT/.build/desktop-mpv}/k7ws2"
mkdir -p "$BUILD"

need() { command -v "$1" >/dev/null || { echo "need $1" >&2; exit 1; }; }
need python3
need gcc

mapfile -t PES < <(find "$DIR" -maxdepth 1 \( -iname '*.dll' -o -iname '*.exe' \) -print | sort)
if ((${#PES[@]} == 0)); then
  echo "ERROR: no PE files in $DIR" >&2
  exit 1
fi

echo "==> gen k7ws2 proxy from ${#PES[@]} PE(s)"
python3 "$ROOT/scripts/gen-k7ws2-proxy.py" --out-dir "$BUILD" "${PES[@]}"

echo "==> compile k7ws2.dll"
# MinGW: .def forwards resolve to system ws2_32 at load time.
gcc -shared -O2 -o "$BUILD/k7ws2.dll" "$BUILD/k7ws2.c" "$BUILD/k7ws2.def" -lws2_32 \
  -Wl,--out-implib,"$BUILD/libk7ws2.dll.a"
cp -f "$BUILD/k7ws2.dll" "$DIR/k7ws2.dll"
echo "ok installed $DIR/k7ws2.dll"

echo "==> PE-patch Win7 imports (time API + WS2_32→k7ws2)"
python3 "$ROOT/scripts/patch-win7-pe-imports.py" "${PES[@]}"

# Gate: no PE should still hard-import GetSystemTimePreciseAsFileTime, or WS2_32 by name.
if command -v objdump >/dev/null 2>&1; then
  bad=0
  for pe in "${PES[@]}"; do
    dump="$(objdump -p "$pe" 2>/dev/null || true)"
    if printf '%s\n' "$dump" | grep -qF 'GetSystemTimePreciseAsFileTime'; then
      echo "ERROR: $pe still references GetSystemTimePreciseAsFileTime" >&2
      bad=1
    fi
    if printf '%s\n' "$dump" | awk 'BEGIN{IGNORECASE=1} /DLL Name:/{dll=$3} /DLL Name:/ && dll ~ /ws2_32/ { bad=1 } END{exit bad?2:0}'; then
      :
    else
      if [[ $? -eq 2 ]]; then
        echo "ERROR: $pe still imports WS2_32.dll (expected k7ws2.dll)" >&2
        bad=1
      fi
    fi
  done
  [[ -f "$DIR/k7ws2.dll" ]] || { echo "ERROR: missing $DIR/k7ws2.dll" >&2; bad=1; }
  [[ "$bad" == "0" ]] || exit 1
fi

echo "ok Win7 k7ws2 proxy ready"
