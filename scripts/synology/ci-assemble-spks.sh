#!/usr/bin/env bash
# 合并 CI piece tar（或本地 dist/syno-pieces/）并打出两个架构的 SPK。
#
# 用法:
#   ./scripts/synology/ci-assemble-spks.sh [pieces-dir]
# 默认 pieces-dir = dist/syno-pieces（内含 syno-*.tar）
#
# 也可把 download-artifact 落到某目录后传入该目录（递归找 *.tar）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=common.sh
source "$ROOT/scripts/synology/common.sh"
kotv_syno_load_versions

PIECES_DIR="${1:-$ROOT/dist/syno-pieces}"
chmod +x "$ROOT/scripts/synology/"*.sh

if [[ ! -d "$PIECES_DIR" ]]; then
  echo "ERROR: pieces dir missing: $PIECES_DIR" >&2
  exit 1
fi

echo "==> extract pieces from $PIECES_DIR → dist/"
mkdir -p "$ROOT/dist"
mapfile -t TARS < <(find "$PIECES_DIR" -type f -name 'syno-*.tar' | sort)
if [[ ${#TARS[@]} -eq 0 ]]; then
  echo "ERROR: no syno-*.tar under $PIECES_DIR" >&2
  exit 1
fi
for t in "${TARS[@]}"; do
  echo "  tar -xf $(basename "$t")"
  tar -xf "$t" -C "$ROOT/dist"
done

# bridge → 各 arch runtime
if [[ -f "$ROOT/dist/syno-bridge/spider-bridge.jar" ]]; then
  for arch in x86_64 armv8; do
    mkdir -p "$ROOT/dist/syno-runtime-${arch}/bridge"
    cp -a "$ROOT/dist/syno-bridge/spider-bridge.jar" \
      "$ROOT/dist/syno-runtime-${arch}/bridge/spider-bridge.jar"
  done
fi

write_runtime_marker() {
  local arch="$1" plat="$2"
  local out="$ROOT/dist/syno-runtime-${arch}"
  mkdir -p "$out"
  cat >"$out/.kotv-runtime" <<EOF
platform=synology-${arch}
toolkit_platform=${plat}
dsm=${SYNO_DSM_VER}
prepared=$(date -u +%Y-%m-%dT%H:%M:%SZ)
assembled=1
EOF
}

write_runtime_marker x86_64 geminilake
write_runtime_marker armv8 rtd1296

WEBAPP="$ROOT/dist/syno-webapp"
for arch in x86_64 armv8; do
  eng="$ROOT/dist/syno-engine-${arch}/kotv-engine"
  rt="$ROOT/dist/syno-runtime-${arch}"
  echo "==> package SPK arch=$arch"
  "$ROOT/scripts/synology/package-spk.sh" "$arch" \
    --engine "$eng" \
    --webapp "$WEBAPP" \
    --runtime-dir "$rt"
done

echo "==> assembled SPKs:"
ls -lh "$ROOT/dist"/KO影视-*-synology-*.spk
