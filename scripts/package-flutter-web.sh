#!/usr/bin/env bash
# Web 发行包 = 引擎 + runtime + webapp（同端口 :9978 由引擎放出 Flutter Web）
# 不进 PC / Android / iOS Flutter 客户端包。
# 用法: ./scripts/package-flutter-web.sh [platform]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=kotv-release-name.sh
source "$ROOT/scripts/kotv-release-name.sh"
# shellcheck source=kotv-win-build-env.sh
source "$ROOT/scripts/kotv-win-build-env.sh"

PLAT="${1:-$(kotv_detect_host_plat)}"
VERSION="$(kotv_release_version "$ROOT/flutter/pubspec.yaml")"
kotv_check_version_literals "$VERSION"
DIST="$ROOT/dist/KOTV-web-$PLAT"
FLUTTER_BIN="${FLUTTER_BIN:-$(command -v flutter || true)}"
if [[ -z "$FLUTTER_BIN" && -x "$HOME/flutter/bin/flutter" ]]; then
  FLUTTER_BIN="$HOME/flutter/bin/flutter"
fi
if [[ -z "$FLUTTER_BIN" ]]; then
  echo "flutter not found; set FLUTTER_BIN" >&2
  exit 1
fi

case "$PLAT" in
  macos-arm64)  export GOOS=darwin  GOARCH=arm64 ;;
  macos-x64)    export GOOS=darwin  GOARCH=amd64 ;;
  linux-arm64)  export GOOS=linux   GOARCH=arm64 ;;
  linux-x64)    export GOOS=linux   GOARCH=amd64 ;;
  windows-x64)    export GOOS=windows GOARCH=amd64 ;;
  windows-arm64)  export GOOS=windows GOARCH=arm64 ;;
  *) echo "unknown platform: $PLAT" >&2; exit 1 ;;
esac

BIN="kotv-engine"
[[ "$GOOS" == "windows" ]] && BIN="kotv-engine.exe"

echo "==> Web package version=$VERSION platform=$PLAT"
chmod +x "$ROOT/bridge/build.sh" "$ROOT"/scripts/*.sh || true

echo "==> prepare runtime"
"$ROOT/scripts/prepare-runtime.sh" "$PLAT"
"$ROOT/scripts/verify-runtime.sh" runtime "$PLAT"

export FLUTTER_BIN
"$ROOT/scripts/build-flutter-webapp.sh"

echo "==> build engine"
(cd "$ROOT/internal/spider" && go run gen_qjsinc.go)
rm -rf "$DIST"
mkdir -p "$DIST/runtime" "$DIST/webapp"

ENGINE_NOTE="CGO 动态链系统库"
VER_LD="$(kotv_engine_version_ldflags "$VERSION")"
if [[ "$GOOS" == "linux" ]]; then
  # 避开 glibc 版本地狱：musl 全静态（runtime/ 仍外置；脚本内同源注入版本）
  chmod +x "$ROOT/scripts/build-engine-static-linux.sh"
  "$ROOT/scripts/build-engine-static-linux.sh" "$DIST/$BIN" "$GOARCH"
  ENGINE_NOTE="musl 全静态（不依赖宿主 glibc）"
elif [[ "$GOOS" == "windows" ]]; then
  if [[ "$PLAT" == "windows-arm64" ]]; then
    kotv_windows_export_cgo_arm64 || exit 1
  fi
  (cd "$ROOT" && CGO_ENABLED=1 go build -ldflags "-s -w ${VER_LD}" -o "$DIST/$BIN" ./cmd/engine)
else
  # macOS：无法真正全静态，接受系统库
  (cd "$ROOT" && CGO_ENABLED=1 go build -ldflags "-s -w ${VER_LD}" -o "$DIST/$BIN" ./cmd/engine)
fi
chmod +x "$DIST/$BIN" 2>/dev/null || true

echo "==> copy runtime + webapp"
cp -a "$ROOT/runtime/." "$DIST/runtime/"
cp -a "$ROOT/flutter/build/web/." "$DIST/webapp/"
# 开发预览目录（gitignore）
rm -rf "$ROOT/webapp"
cp -a "$DIST/webapp" "$ROOT/webapp"

# 纯静态 overlay：可丢进任意已有引擎旁路 webapp/
STATIC_ZIP="$ROOT/dist/KO影视-${VERSION}-web-static.zip"
mkdir -p "$ROOT/dist"
rm -f "$STATIC_ZIP"
(cd "$DIST/webapp" && zip -r -q "$STATIC_ZIP" .)

cat > "$DIST/README.txt" <<EOF
KO影视 Web 包 ($PLAT)

本包 = Go 引擎 + 运行时 + Flutter Web（webapp/）。
引擎在 :9978 直接放出 Web 客户端（与 API 同端口）。
引擎链接: $ENGINE_NOTE
runtime/（JRE/Python 等）外置，不编进引擎。

启动:
  ./$BIN
  # 或指定静态目录: KOTV_WEBAPP=/path/to/webapp ./$BIN

浏览器:
  http://127.0.0.1:9978/          ← Web 客户端
  http://127.0.0.1:9978/remote/   ← 遥控页
  http://127.0.0.1:9978/admin/    ← 用户管理

说明:
  - 与 PC / Android / iOS 客户端包分离，不互相嵌入。
  - 仅当可执行文件旁存在 webapp/index.html（或 KOTV_WEBAPP）时，/ 才是 Web；否则 / 为遥控。
  - 也可只解压「web-static」到已有引擎目录下的 webapp/。
EOF

OUT_ZIP="$ROOT/dist/KO影视-${VERSION}-web-${PLAT}.zip"
# 发行名与其它包保持一致：linux-x64 → linux-x86_64
case "$PLAT" in
  linux-x64) OUT_ZIP="$ROOT/dist/KO影视-${VERSION}-web-linux-x86_64.zip" ;;
  linux-arm64) OUT_ZIP="$ROOT/dist/KO影视-${VERSION}-web-linux-aarch64.zip" ;;
  macos-arm64) OUT_ZIP="$ROOT/dist/KO影视-${VERSION}-web-aarch64.zip" ;;
  macos-x64) OUT_ZIP="$ROOT/dist/KO影视-${VERSION}-web-x86_64.zip" ;;
  windows-x64) OUT_ZIP="$ROOT/dist/KO影视-${VERSION}-web-x86_64.zip" ;;
  windows-arm64) OUT_ZIP="$ROOT/dist/KO影视-${VERSION}-web-arm64.zip" ;;
esac
rm -f "$OUT_ZIP"
(cd "$DIST" && zip -r -q "$OUT_ZIP" .)
ls -lh "$OUT_ZIP" "$STATIC_ZIP"
echo "done: $DIST"
