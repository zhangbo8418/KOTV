#!/usr/bin/env bash
# CI：保证 Windows runner 上有可用的 nasm。
# choco community feed 偶发 503；失败后直下官方 win64 zip。
set -euo pipefail

NASM_VER="${KOTV_NASM_VERSION:-2.16.03}"
NASM_DIR="/c/Program Files/NASM"
NASM_DIR_WIN='C:\Program Files\NASM'

kotv_nasm_ready() {
  command -v nasm >/dev/null 2>&1 || return 1
  nasm -v >/dev/null 2>&1 || return 1
  return 0
}

kotv_export_nasm_path() {
  local dir="$1" win
  win="$(cygpath -w "$dir" 2>/dev/null || echo "$dir")"
  export PATH="${dir}:$PATH"
  if [[ -n "${GITHUB_PATH:-}" ]]; then
    echo "$win" >>"$GITHUB_PATH"
  fi
  echo "ok nasm=$(command -v nasm) $(nasm -v 2>&1 | head -1)"
}

kotv_choco_install_nasm() {
  local i
  for i in 1 2 3; do
    echo "==> choco install nasm (attempt $i)"
    if choco install nasm -y --no-progress; then
      return 0
    fi
    echo "WARN: choco nasm attempt $i failed" >&2
    sleep $((i * 5))
  done
  return 1
}

kotv_zip_install_nasm() {
  local url zip stage
  url="${KOTV_NASM_URL:-https://www.nasm.us/pub/nasm/releasebuilds/${NASM_VER}/win64/nasm-${NASM_VER}-win64.zip}"
  zip="${RUNNER_TEMP:-/tmp}/nasm-${NASM_VER}-win64.zip"
  stage="${RUNNER_TEMP:-/tmp}/nasm-${NASM_VER}-extract"
  echo "==> download NASM ${NASM_VER} zip"
  curl -fsSL --connect-timeout 30 --retry 3 --retry-delay 5 --max-time 300 -o "$zip" "$url" \
    || { echo "ERROR: download NASM failed: $url" >&2; return 1; }
  rm -rf "$stage"
  mkdir -p "$stage"
  unzip -qo "$zip" -d "$stage"
  # zip 顶层多为 nasm-<ver>/nasm.exe
  local bin
  bin="$(find "$stage" -type f -name nasm.exe | head -1)"
  [[ -n "$bin" ]] || { echo "ERROR: nasm.exe missing in zip" >&2; find "$stage" -maxdepth 3 -type f >&2 || true; return 1; }
  mkdir -p "$NASM_DIR"
  cp -f "$(dirname "$bin")"/* "$NASM_DIR/"
  [[ -f "$NASM_DIR/nasm.exe" ]] || { echo "ERROR: copy to $NASM_DIR failed" >&2; return 1; }
  kotv_export_nasm_path "$NASM_DIR"
}

main() {
  # 已装过（含 choco 默认 C:\Program Files\NASM）
  export PATH="/c/Program Files/NASM:/c/ProgramData/chocolatey/bin:$PATH"
  if kotv_nasm_ready; then
    kotv_export_nasm_path "$(dirname "$(command -v nasm)")"
    return 0
  fi

  kotv_choco_install_nasm || true
  export PATH="/c/Program Files/NASM:/c/ProgramData/chocolatey/bin:$PATH"
  if kotv_nasm_ready; then
    kotv_export_nasm_path "$(dirname "$(command -v nasm)")"
    return 0
  fi

  echo "WARN: choco nasm unavailable; falling back to official win64 zip" >&2
  kotv_zip_install_nasm
  kotv_nasm_ready || { echo "ERROR: nasm still missing after zip install" >&2; exit 1; }
}

main "$@"
