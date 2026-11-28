#!/usr/bin/env bash
# 组装群晖 SPK：Toolkit 全静态引擎 + webapp + Toolkit 运行时（Web 服务形态）。
# 用法:
#   ./scripts/synology/package-spk.sh <x86_64|armv8> \
#     --engine PATH --webapp DIR --runtime-dir DIR [--version VER]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../kotv-release-name.sh
source "$ROOT/scripts/kotv-release-name.sh"
# shellcheck source=common.sh
source "$ROOT/scripts/synology/common.sh"
kotv_syno_load_versions

ARCH="${1:?usage: package-spk.sh <x86_64|armv8> --engine E --webapp W --runtime-dir R}"
shift || true

ENGINE=""
WEBAPP=""
RUNTIME_DIR=""
VERSION="$(kotv_release_version "$ROOT/flutter/pubspec.yaml")"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --engine) ENGINE="${2:?}"; shift 2 ;;
    --webapp) WEBAPP="${2:?}"; shift 2 ;;
    --runtime-dir) RUNTIME_DIR="${2:?}"; shift 2 ;;
    --version) VERSION="${2:?}"; shift 2 ;;
    --web-dir)
      echo "ERROR: --web-dir 已移除；请分别传 --engine 与 --webapp" >&2
      exit 1
      ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

case "$ARCH" in
  x86_64)
    ENGINE="${ENGINE:-$ROOT/dist/syno-engine-x86_64/kotv-engine}"
    RUNTIME_DIR="${RUNTIME_DIR:-$ROOT/dist/syno-runtime-x86_64}"
    INFO_ARCH="x86_64"
    ;;
  armv8)
    ENGINE="${ENGINE:-$ROOT/dist/syno-engine-armv8/kotv-engine}"
    RUNTIME_DIR="${RUNTIME_DIR:-$ROOT/dist/syno-runtime-armv8}"
    INFO_ARCH="rtd1296 armada37xx"
    ;;
  *)
    echo "arch must be x86_64 or armv8" >&2
    exit 1
    ;;
esac
WEBAPP="${WEBAPP:-$ROOT/dist/syno-webapp}"

VERSION="${VERSION#v}"
BUILD_NO="$(sed -nE 's/^version:[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+\+([0-9]+).*/\1/p' "$ROOT/flutter/pubspec.yaml" | head -1)"
BUILD_NO="${BUILD_NO:-1}"
SPK_VER="${VERSION}-${BUILD_NO}"

META="$ROOT/synology/kotv"
STAGING="$ROOT/dist/spk-staging-${ARCH}"
PKG_ROOT="$STAGING/package"
SPK_OUT="$ROOT/dist/KO影视-${VERSION}-synology-${ARCH}.spk"

echo "==> SPK arch=$ARCH version=$SPK_VER"
echo "    engine=$ENGINE"
echo "    webapp=$WEBAPP"
echo "    runtime=$RUNTIME_DIR"

kotv_syno_assert_static_engine "$ENGINE"
if [[ ! -f "$WEBAPP/index.html" ]]; then
  echo "ERROR: missing webapp: $WEBAPP/index.html" >&2
  exit 1
fi
for need in node python jre chromium; do
  if [[ ! -e "$RUNTIME_DIR/$need" ]]; then
    echo "ERROR: missing Toolkit runtime: $RUNTIME_DIR/$need" >&2
    exit 1
  fi
done
[[ -x "$RUNTIME_DIR/node/node" ]] || { echo "ERROR: missing node" >&2; exit 1; }
[[ -x "$RUNTIME_DIR/jre/bin/java" ]] || { echo "ERROR: missing java" >&2; exit 1; }
if [[ ! -x "$RUNTIME_DIR/chromium/chrome-headless-shell" && ! -x "$RUNTIME_DIR/chromium/chrome" ]]; then
  echo "ERROR: missing chromium headless" >&2
  exit 1
fi

rm -rf "$STAGING"
mkdir -p "$PKG_ROOT/runtime" "$PKG_ROOT/webapp" "$STAGING/scripts" "$STAGING/conf"

cp -a "$ENGINE" "$PKG_ROOT/kotv-engine"
chmod 755 "$PKG_ROOT/kotv-engine"
cp -a "$WEBAPP/." "$PKG_ROOT/webapp/"

rm -rf "$PKG_ROOT/runtime"
mkdir -p "$PKG_ROOT/runtime"
cp -a "$RUNTIME_DIR/node" "$PKG_ROOT/runtime/node"
cp -a "$RUNTIME_DIR/python" "$PKG_ROOT/runtime/python"
cp -a "$RUNTIME_DIR/jre" "$PKG_ROOT/runtime/jre"
cp -a "$RUNTIME_DIR/chromium" "$PKG_ROOT/runtime/chromium"
[[ -d "$RUNTIME_DIR/ffmpeg" ]] && cp -a "$RUNTIME_DIR/ffmpeg" "$PKG_ROOT/runtime/ffmpeg"

mkdir -p "$PKG_ROOT/runtime/bridge"
if [[ ! -f "$RUNTIME_DIR/bridge/spider-bridge.jar" ]]; then
  echo "ERROR: missing $RUNTIME_DIR/bridge/spider-bridge.jar（先跑 ci-build-piece bridge / assemble）" >&2
  exit 1
fi
cp -a "$RUNTIME_DIR/bridge/spider-bridge.jar" "$PKG_ROOT/runtime/bridge/"
[[ -f "$RUNTIME_DIR/.kotv-runtime" ]] && cp -a "$RUNTIME_DIR/.kotv-runtime" "$PKG_ROOT/runtime/.kotv-runtime"

install -m 755 "$META/scripts/start-stop-status" "$STAGING/scripts/start-stop-status"
for s in preinst postinst preuninst postuninst preupgrade postupgrade; do
  install -m 755 "$META/scripts/$s" "$STAGING/scripts/$s"
done
cp -a "$META/conf/." "$STAGING/conf/"
mkdir -p "$PKG_ROOT/conf"
cp -a "$META/conf/kotv.sc" "$PKG_ROOT/conf/kotv.sc"

CTIME="$(date +%s)"
sed \
  -e "s/__VERSION__/${SPK_VER}/g" \
  -e "s/__ARCH__/${INFO_ARCH}/g" \
  -e "s/__CTIME__/${CTIME}/g" \
  "$META/INFO.in" >"$STAGING/INFO"
cp -a "$META/PACKAGE_ICON.PNG" "$STAGING/PACKAGE_ICON.PNG"
cp -a "$META/PACKAGE_ICON_256.PNG" "$STAGING/PACKAGE_ICON_256.PNG"

echo "==> create package.tgz"
(cd "$PKG_ROOT" && tar -czf "$STAGING/package.tgz" .)
EXTRACT_KB="$(du -sk "$PKG_ROOT" | awk '{print $1}')"
echo "extractsize=${EXTRACT_KB}" >>"$STAGING/INFO"
echo "checksum=\"$(cksum "$STAGING/package.tgz" | awk '{print $1}')\"" >>"$STAGING/INFO"

mkdir -p "$ROOT/dist"
rm -f "$SPK_OUT"
(
  cd "$STAGING"
  tar -cf "$SPK_OUT" \
    INFO PACKAGE_ICON.PNG PACKAGE_ICON_256.PNG package.tgz scripts conf
)
ls -lh "$SPK_OUT"
echo "done: $SPK_OUT"
