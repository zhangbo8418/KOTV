#!/usr/bin/env bash
# 群晖 SPK 一站入口（CI）：Toolkit 编引擎+运行时，Web 形态（webapp），打 SPK。
# 用法: ./scripts/synology/build-spk.sh <braswell|rtd1296>
#
# 产物:
#   dist/syno-engine-{arch}/kotv-engine
#   dist/syno-runtime-{arch}/
#   dist/KO影视-{ver}-synology-{arch}.spk
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=common.sh
source "$ROOT/scripts/synology/common.sh"
kotv_syno_load_versions

PLATFORM="${1:?usage: build-spk.sh <braswell|rtd1296>}"
read -r ARCH_LABEL _GOARCH _TARGET <<<"$(kotv_syno_plat_meta "$PLATFORM")"

chmod +x "$ROOT/scripts/synology/"*.sh "$ROOT/scripts/build-flutter-webapp.sh"

echo "======== Synology SPK: $PLATFORM ($ARCH_LABEL) ========"

"$ROOT/scripts/synology/deploy-toolkit.sh" "$PLATFORM"

WEBAPP="$ROOT/dist/syno-webapp"
if [[ ! -f "$WEBAPP/index.html" ]]; then
  "$ROOT/scripts/build-flutter-webapp.sh" "$WEBAPP"
fi

ENGINE_OUT="$ROOT/dist/syno-engine-${ARCH_LABEL}/kotv-engine"
"$ROOT/scripts/synology/build-engine.sh" "$PLATFORM" "$ENGINE_OUT"

"$ROOT/scripts/synology/build-runtime-in-chroot.sh" "$PLATFORM"

# bridge 进 runtime
if [[ ! -f "$ROOT/bridge/spider-bridge.jar" ]]; then
  (cd "$ROOT" && ./bridge/build.sh)
fi
mkdir -p "$ROOT/dist/syno-runtime-${ARCH_LABEL}/bridge"
cp -a "$ROOT/bridge/spider-bridge.jar" "$ROOT/dist/syno-runtime-${ARCH_LABEL}/bridge/"

"$ROOT/scripts/synology/package-spk.sh" "$ARCH_LABEL" \
  --engine "$ENGINE_OUT" \
  --webapp "$WEBAPP" \
  --runtime-dir "$ROOT/dist/syno-runtime-${ARCH_LABEL}"

echo "======== Synology SPK done ($ARCH_LABEL) ========"
