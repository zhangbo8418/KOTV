#!/usr/bin/env bash
# CI / 本地：编一块群晖产物，并打成可上传的 piece tar（相对 dist/ 的路径）。
#
# 用法:
#   ./scripts/synology/ci-build-piece.sh runtime <geminilake|rtd1296> <node|python|jre|chromium|ffmpeg>
#   ./scripts/synology/ci-build-piece.sh engine  <geminilake|rtd1296>
#   ./scripts/synology/ci-build-piece.sh webapp
#   ./scripts/synology/ci-build-piece.sh bridge
#
# 产出:
#   dist/syno-pieces/<artifact-name>.tar
#   （内容为相对 dist/ 的路径，assemble 时 tar -xf -C dist）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=common.sh
source "$ROOT/scripts/synology/common.sh"
kotv_syno_load_versions

KIND="${1:?usage: ci-build-piece.sh runtime|engine|webapp|bridge ...}"
shift || true

PIECES_DIR="$ROOT/dist/syno-pieces"
mkdir -p "$PIECES_DIR" "$ROOT/dist"
chmod +x "$ROOT/scripts/synology/"*.sh "$ROOT/scripts/build-flutter-webapp.sh" "$ROOT/bridge/build.sh"

pack_tar() {
  local art="$1"
  shift
  local out="$PIECES_DIR/${art}.tar"
  rm -f "$out"
  # "$@" = paths relative to dist/
  (cd "$ROOT/dist" && tar -cf "$out" "$@")
  ls -lh "$out"
  echo "piece=$art tar=$out"
}

case "$KIND" in
  runtime)
    PLATFORM="${1:?runtime needs toolkit platform}"
    COMP="${2:?runtime needs component}"
    read -r ARCH_LABEL _GOARCH _TARGET <<<"$(kotv_syno_plat_meta "$PLATFORM")"
    case " $(kotv_syno_runtime_components) " in
      *" $COMP "*) ;;
      *) echo "ERROR: unknown runtime component: $COMP" >&2; exit 1 ;;
    esac
    "$ROOT/scripts/synology/deploy-toolkit.sh" "$PLATFORM"
    export KOTV_SYNO_COMPONENTS="$COMP"
    "$ROOT/scripts/synology/build-runtime-in-chroot.sh" "$PLATFORM"
    # 只打包本组件目录 + stamp（相对 dist/）
    local_comp="syno-runtime-${ARCH_LABEL}/${COMP}"
    local_stamp="syno-runtime-${ARCH_LABEL}/.kotv-syno-${COMP}"
    if [[ ! -e "$ROOT/dist/${local_comp}" ]]; then
      echo "ERROR: missing component output: dist/${local_comp}" >&2
      exit 1
    fi
    if [[ ! -f "$ROOT/dist/${local_stamp}" ]]; then
      echo "ERROR: missing stamp: dist/${local_stamp}" >&2
      exit 1
    fi
    pack_tar "$(kotv_syno_artifact_name "$COMP" "$ARCH_LABEL")" "$local_comp" "$local_stamp"
    ;;
  engine)
    PLATFORM="${1:?engine needs toolkit platform}"
    read -r ARCH_LABEL _GOARCH _TARGET <<<"$(kotv_syno_plat_meta "$PLATFORM")"
    OUT="$ROOT/dist/syno-engine-${ARCH_LABEL}/kotv-engine"
    "$ROOT/scripts/synology/deploy-toolkit.sh" "$PLATFORM"
    "$ROOT/scripts/synology/build-engine.sh" "$PLATFORM" "$OUT"
    pack_tar "$(kotv_syno_artifact_name engine "$ARCH_LABEL")" "syno-engine-${ARCH_LABEL}/kotv-engine"
    ;;
  webapp)
    WEBAPP="$ROOT/dist/syno-webapp"
    if [[ ! -f "$WEBAPP/index.html" ]]; then
      "$ROOT/scripts/build-flutter-webapp.sh" "$WEBAPP"
    fi
    pack_tar "$(kotv_syno_artifact_name webapp any)" "syno-webapp"
    ;;
  bridge)
    if [[ ! -f "$ROOT/bridge/spider-bridge.jar" ]]; then
      (cd "$ROOT" && ./bridge/build.sh)
    fi
    mkdir -p "$ROOT/dist/syno-bridge"
    cp -a "$ROOT/bridge/spider-bridge.jar" "$ROOT/dist/syno-bridge/spider-bridge.jar"
    pack_tar "$(kotv_syno_artifact_name bridge any)" "syno-bridge/spider-bridge.jar"
    ;;
  *)
    echo "ERROR: unknown kind: $KIND (want runtime|engine|webapp|bridge)" >&2
    exit 1
    ;;
esac
