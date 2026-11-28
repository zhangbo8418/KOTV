#!/usr/bin/env bash
# 群晖 SPK 引擎：复用 musl 全静态 Linux 引擎（小体积，不依赖 DSM glibc）。
# 用法: ./scripts/synology/build-engine.sh <geminilake|rtd1296> [out-path]
#
# 实际编译在 scripts/build-engine-static-linux.sh（-trimpath -ldflags="-s -w ..."）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=common.sh
source "$ROOT/scripts/synology/common.sh"

PLATFORM="${1:?usage: build-engine.sh <geminilake|rtd1296> [out]}"
read -r ARCH_LABEL GOARCH _TARGET <<<"$(kotv_syno_plat_meta "$PLATFORM")"
OUT="${2:-$ROOT/dist/syno-engine-${ARCH_LABEL}/kotv-engine}"

mkdir -p "$(dirname "$OUT")"
chmod +x "$ROOT/scripts/build-engine-static-linux.sh"

echo "==> Synology engine $PLATFORM ($ARCH_LABEL / GOARCH=$GOARCH) → static $OUT"
"$ROOT/scripts/build-engine-static-linux.sh" "$OUT" "$GOARCH"
kotv_syno_assert_static_engine "$OUT"
echo "$OUT"
