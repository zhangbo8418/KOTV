#!/usr/bin/env bash
# 群晖 SPK 本地一站入口（逐块 ci-build-piece → package）。
# CI：workflow 矩阵各跑一块，最后 ci-assemble-spks.sh 合并打 SPK。
#
# 用法: ./scripts/synology/build-spk.sh <geminilake|rtd1296|all>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=common.sh
source "$ROOT/scripts/synology/common.sh"
kotv_syno_load_versions

ARG="${1:?usage: build-spk.sh <geminilake|rtd1296|all>}"
chmod +x "$ROOT/scripts/synology/"*.sh

"$ROOT/scripts/synology/ci-build-piece.sh" webapp
"$ROOT/scripts/synology/ci-build-piece.sh" bridge

build_plat_pieces() {
  local plat="$1" c
  "$ROOT/scripts/synology/ci-build-piece.sh" engine "$plat"
  for c in $(kotv_syno_runtime_components); do
    "$ROOT/scripts/synology/ci-build-piece.sh" runtime "$plat" "$c"
  done
}

package_one() {
  local plat="$1" arch
  read -r arch _ <<<"$(kotv_syno_plat_meta "$plat")"
  mkdir -p "$ROOT/dist/syno-runtime-${arch}/bridge"
  cp -a "$ROOT/dist/syno-bridge/spider-bridge.jar" \
    "$ROOT/dist/syno-runtime-${arch}/bridge/spider-bridge.jar"
  cat >"$ROOT/dist/syno-runtime-${arch}/.kotv-runtime" <<EOF
platform=synology-${arch}
toolkit_platform=${plat}
dsm=${SYNO_DSM_VER}
prepared=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
  "$ROOT/scripts/synology/package-spk.sh" "$arch" \
    --engine "$ROOT/dist/syno-engine-${arch}/kotv-engine" \
    --webapp "$ROOT/dist/syno-webapp" \
    --runtime-dir "$ROOT/dist/syno-runtime-${arch}"
}

case "$ARG" in
  all)
    build_plat_pieces geminilake
    build_plat_pieces rtd1296
    package_one geminilake
    package_one rtd1296
    ;;
  geminilake|rtd1296)
    build_plat_pieces "$ARG"
    package_one "$ARG"
    ;;
  *)
    echo "usage: build-spk.sh <geminilake|rtd1296|all>" >&2
    exit 1
    ;;
esac

echo "======== Synology SPK done ($ARG) ========"
ls -lh "$ROOT/dist"/KO影视-*-synology-*.spk
