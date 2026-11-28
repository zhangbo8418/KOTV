#!/usr/bin/env bash
# 群晖 SPK 一站入口（CI）：Toolkit 编引擎+运行时，Web 形态（webapp），打 SPK。
# 用法: ./scripts/synology/build-spk.sh <geminilake|rtd1296>
#
# deploy-toolkit 之后并行：webapp / engine / runtime(组件再并行) / bridge.jar
# 产物:
#   dist/syno-engine-{arch}/kotv-engine
#   dist/syno-runtime-{arch}/
#   dist/KO影视-{ver}-synology-{arch}.spk
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=common.sh
source "$ROOT/scripts/synology/common.sh"
kotv_syno_load_versions

PLATFORM="${1:?usage: build-spk.sh <geminilake|rtd1296>}"
read -r ARCH_LABEL _GOARCH _TARGET <<<"$(kotv_syno_plat_meta "$PLATFORM")"

chmod +x "$ROOT/scripts/synology/"*.sh "$ROOT/scripts/build-flutter-webapp.sh" "$ROOT/bridge/build.sh"

echo "======== Synology SPK: $PLATFORM ($ARCH_LABEL) ========"

"$ROOT/scripts/synology/deploy-toolkit.sh" "$PLATFORM"

WEBAPP="$ROOT/dist/syno-webapp"
ENGINE_OUT="$ROOT/dist/syno-engine-${ARCH_LABEL}/kotv-engine"
RUNTIME_DIR="$ROOT/dist/syno-runtime-${ARCH_LABEL}"
LOGDIR="$ROOT/.syno-build/${PLATFORM}/spk-stage-logs"
export KOTV_SYNO_PARALLEL_LOGDIR="$LOGDIR"
mkdir -p "$LOGDIR"

# Toolkit 就绪后四路并行（各自独立进程，互不抢同一 BUILD 子目录）
echo "==> parallel stages: webapp / engine / runtime / bridge"
kotv_syno_parallel \
  "webapp:if [[ -f \"$WEBAPP/index.html\" ]]; then echo \"webapp cache hit: $WEBAPP\"; else \"$ROOT/scripts/build-flutter-webapp.sh\" \"$WEBAPP\"; fi" \
  "engine:$ROOT/scripts/synology/build-engine.sh \"$PLATFORM\" \"$ENGINE_OUT\"" \
  "runtime:$ROOT/scripts/synology/build-runtime-in-chroot.sh \"$PLATFORM\"" \
  "bridge:if [[ -f \"$ROOT/bridge/spider-bridge.jar\" ]]; then echo \"bridge cache hit\"; else (cd \"$ROOT\" && ./bridge/build.sh); fi"

mkdir -p "$RUNTIME_DIR/bridge"
cp -a "$ROOT/bridge/spider-bridge.jar" "$RUNTIME_DIR/bridge/"

"$ROOT/scripts/synology/package-spk.sh" "$ARCH_LABEL" \
  --engine "$ENGINE_OUT" \
  --webapp "$WEBAPP" \
  --runtime-dir "$RUNTIME_DIR"

echo "======== Synology SPK done ($ARCH_LABEL) ========"
