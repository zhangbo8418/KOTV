#!/usr/bin/env bash
# 组装群晖 SPK：musl 静态引擎 + webapp + Toolkit 运行时
# 用法:
#   ./scripts/synology/package-spk.sh <x86_64|armv8> \
#     [--web-dir DIR] [--runtime-dir DIR] [--version VER]
#
# 默认:
#   web-dir:     dist/KOTV-web-linux-x64 或 linux-arm64（按 arch）
#   runtime-dir: dist/syno-runtime-{arch}
# 产出: dist/KO影视-{ver}-synology-{arch}.spk
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../kotv-release-name.sh
source "$ROOT/scripts/kotv-release-name.sh"
# shellcheck source=versions.env
source "$ROOT/scripts/synology/versions.env"

ARCH="${1:?usage: package-spk.sh <x86_64|armv8> [--web-dir D] [--runtime-dir D]}"
shift || true

WEB_DIR=""
RUNTIME_DIR=""
VERSION="$(kotv_release_version "$ROOT/flutter/pubspec.yaml")"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --web-dir) WEB_DIR="${2:?}"; shift 2 ;;
    --runtime-dir) RUNTIME_DIR="${2:?}"; shift 2 ;;
    --version) VERSION="${2:?}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

case "$ARCH" in
  x86_64)
    WEB_DIR="${WEB_DIR:-$ROOT/dist/KOTV-web-linux-x64}"
    RUNTIME_DIR="${RUNTIME_DIR:-$ROOT/dist/syno-runtime-x86_64}"
    INFO_ARCH="x86_64"
    ;;
  armv8)
    WEB_DIR="${WEB_DIR:-$ROOT/dist/KOTV-web-linux-arm64}"
    RUNTIME_DIR="${RUNTIME_DIR:-$ROOT/dist/syno-runtime-armv8}"
    INFO_ARCH="rtd1296 armada37xx"
    ;;
  *)
    echo "arch must be x86_64 or armv8" >&2
    exit 1
    ;;
esac

VERSION="${VERSION#v}"
# Synology version: x.y.z-build
BUILD_NO="$(sed -nE 's/^version:[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+\+([0-9]+).*/\1/p' "$ROOT/flutter/pubspec.yaml" | head -1)"
BUILD_NO="${BUILD_NO:-1}"
SPK_VER="${VERSION}-${BUILD_NO}"

META="$ROOT/synology/kotv"
STAGING="$ROOT/dist/spk-staging-${ARCH}"
PKG_ROOT="$STAGING/package"
SPK_OUT="$ROOT/dist/KO影视-${VERSION}-synology-${ARCH}.spk"

echo "==> SPK arch=$ARCH version=$SPK_VER"
echo "    web=$WEB_DIR"
echo "    runtime=$RUNTIME_DIR"

if [[ ! -x "$WEB_DIR/kotv-engine" ]]; then
  echo "ERROR: missing $WEB_DIR/kotv-engine (先跑 package-flutter-web)" >&2
  exit 1
fi
if [[ ! -d "$WEB_DIR/webapp" || ! -f "$WEB_DIR/webapp/index.html" ]]; then
  echo "ERROR: missing webapp in $WEB_DIR" >&2
  exit 1
fi
for need in node python jre chromium; do
  if [[ ! -e "$RUNTIME_DIR/$need" ]]; then
    echo "ERROR: missing Toolkit runtime component: $RUNTIME_DIR/$need" >&2
    exit 1
  fi
done
if [[ ! -x "$RUNTIME_DIR/node/node" ]]; then
  echo "ERROR: missing $RUNTIME_DIR/node/node" >&2
  exit 1
fi
if [[ ! -x "$RUNTIME_DIR/jre/bin/java" ]]; then
  echo "ERROR: missing $RUNTIME_DIR/jre/bin/java" >&2
  exit 1
fi
if [[ ! -x "$RUNTIME_DIR/chromium/chrome-headless-shell" && ! -x "$RUNTIME_DIR/chromium/chrome" ]]; then
  echo "ERROR: missing chromium headless binary in $RUNTIME_DIR/chromium" >&2
  exit 1
fi

rm -rf "$STAGING"
mkdir -p "$PKG_ROOT/runtime" "$PKG_ROOT/webapp" "$STAGING/scripts" "$STAGING/conf"

# 引擎 + webapp
cp -a "$WEB_DIR/kotv-engine" "$PKG_ROOT/kotv-engine"
chmod 755 "$PKG_ROOT/kotv-engine"
cp -a "$WEB_DIR/webapp/." "$PKG_ROOT/webapp/"

# Toolkit 运行时（不拿 web 包里的 glibc 预编译 runtime）
rm -rf "$PKG_ROOT/runtime"
mkdir -p "$PKG_ROOT/runtime"
cp -a "$RUNTIME_DIR/node" "$PKG_ROOT/runtime/node"
cp -a "$RUNTIME_DIR/python" "$PKG_ROOT/runtime/python"
cp -a "$RUNTIME_DIR/jre" "$PKG_ROOT/runtime/jre"
cp -a "$RUNTIME_DIR/chromium" "$PKG_ROOT/runtime/chromium"
if [[ -d "$RUNTIME_DIR/ffmpeg" ]]; then
  cp -a "$RUNTIME_DIR/ffmpeg" "$PKG_ROOT/runtime/ffmpeg"
fi

# bridge：优先 Toolkit 产物旁，否则仓库 / web 包
mkdir -p "$PKG_ROOT/runtime/bridge"
if [[ -f "$RUNTIME_DIR/bridge/spider-bridge.jar" ]]; then
  cp -a "$RUNTIME_DIR/bridge/spider-bridge.jar" "$PKG_ROOT/runtime/bridge/"
elif [[ -f "$WEB_DIR/runtime/bridge/spider-bridge.jar" ]]; then
  cp -a "$WEB_DIR/runtime/bridge/spider-bridge.jar" "$PKG_ROOT/runtime/bridge/"
elif [[ -f "$ROOT/bridge/spider-bridge.jar" ]]; then
  cp -a "$ROOT/bridge/spider-bridge.jar" "$PKG_ROOT/runtime/bridge/"
else
  echo "==> building bridge jar"
  (cd "$ROOT" && ./bridge/build.sh)
  cp -a "$ROOT/bridge/spider-bridge.jar" "$PKG_ROOT/runtime/bridge/"
fi

if [[ -f "$RUNTIME_DIR/.kotv-runtime" ]]; then
  cp -a "$RUNTIME_DIR/.kotv-runtime" "$PKG_ROOT/runtime/.kotv-runtime"
fi

# 生命周期脚本
install -m 755 "$META/scripts/start-stop-status" "$STAGING/scripts/start-stop-status"
for s in preinst postinst preuninst postuninst preupgrade postupgrade; do
  install -m 755 "$META/scripts/$s" "$STAGING/scripts/$s"
done

# conf
cp -a "$META/conf/." "$STAGING/conf/"
# package 内也放一份 port 描述供 privilege/resource 引用
mkdir -p "$PKG_ROOT/conf"
cp -a "$META/conf/kotv.sc" "$PKG_ROOT/conf/kotv.sc"

# INFO
CTIME="$(date +%s)"
sed \
  -e "s/__VERSION__/${SPK_VER}/g" \
  -e "s/__ARCH__/${INFO_ARCH}/g" \
  -e "s/__CTIME__/${CTIME}/g" \
  "$META/INFO.in" >"$STAGING/INFO"

# icons
cp -a "$META/PACKAGE_ICON.PNG" "$STAGING/PACKAGE_ICON.PNG"
cp -a "$META/PACKAGE_ICON_256.PNG" "$STAGING/PACKAGE_ICON_256.PNG"

# package.tgz
echo "==> create package.tgz"
(cd "$PKG_ROOT" && tar -czf "$STAGING/package.tgz" .)

# extractsize（KB）
EXTRACT_KB="$(du -sk "$PKG_ROOT" | awk '{print $1}')"
echo "extractsize=${EXTRACT_KB}" >>"$STAGING/INFO"
echo "checksum=\"$(cksum "$STAGING/package.tgz" | awk '{print $1}')\"" >>"$STAGING/INFO"

# SPK = tar of INFO + package.tgz + scripts + conf + icons（无顶层目录）
echo "==> create $SPK_OUT"
mkdir -p "$ROOT/dist"
rm -f "$SPK_OUT"
(
  cd "$STAGING"
  tar -cf "$SPK_OUT" \
    INFO \
    PACKAGE_ICON.PNG \
    PACKAGE_ICON_256.PNG \
    package.tgz \
    scripts \
    conf
)

ls -lh "$SPK_OUT"
echo "done: $SPK_OUT"
