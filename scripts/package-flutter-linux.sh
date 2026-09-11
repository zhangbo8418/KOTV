#!/usr/bin/env bash
# 打包 Flutter Linux：runtime + Go 引擎 + UI → ZIP
# 产物：dist/KO影视-{ver}-linux-x86_64.zip
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=kotv-release-name.sh
source "$ROOT/scripts/kotv-release-name.sh"
export PATH="${HOME}/flutter/bin:${PATH}"

VERSION="$(kotv_release_version "$ROOT/flutter/pubspec.yaml")"
OUT_ZIP="$ROOT/dist/KO影视-${VERSION}-linux-x86_64.zip"
ENGINE_OUT="$ROOT/flutter/assets/engine/kotv-engine"
BUNDLE="$ROOT/flutter/build/linux/x64/release/bundle"

echo "==> Flutter Linux package version=$VERSION"

chmod +x "$ROOT/bridge/build.sh" "$ROOT"/scripts/*.sh
echo "==> fetch desktop libmpv (AV3A source)"
"$ROOT/scripts/fetch-desktop-mpv-libs.sh"
"$ROOT/scripts/prepare-runtime.sh" linux-x64
"$ROOT/scripts/verify-runtime.sh" runtime linux-x64

echo "==> build Go engine"
(cd "$ROOT/internal/spider" && go run gen_qjsinc.go)
# proxy.golang.org 偶发 INTERNAL_ERROR；多源 + 重试
export GOPROXY="${GOPROXY:-https://proxy.golang.org,direct}"
ok_eng=0
for attempt in 1 2 3; do
  if (cd "$ROOT" && CGO_ENABLED=1 go build -ldflags "-s -w" -o "$ENGINE_OUT" ./cmd/engine); then
    ok_eng=1
    break
  fi
  echo "WARN: go build engine failed (attempt $attempt); retry..." >&2
  sleep $((attempt * 5))
done
[[ "$ok_eng" == 1 ]] || { echo "ERROR: go build engine failed after retries" >&2; exit 1; }
chmod +x "$ENGINE_OUT"

echo "==> flutter build linux --release"
cd "$ROOT/flutter"
# 资产里若有 Windows .exe / 错架构二进制，清掉无害；Linux 引擎由下方 CMake/拷贝处理
rm -f assets/engine/kotv-engine.exe
# shellcheck source=kotv-fvp-deps.sh
source "$ROOT/scripts/kotv-fvp-deps.sh"
kotv_export_fvp_deps
flutter config --enable-linux-desktop
"$ROOT/scripts/flutter-pub-get.sh"
# mpv/FFmpeg 源码编可能留下 Unix Makefiles 等 CMake 变量；Flutter Linux 需要 Ninja + C 语言。
unset CMAKE_GENERATOR CMAKE_TOOLCHAIN_FILE CMAKE_C_COMPILER CMAKE_CXX_COMPILER || true
# 失败时打出详细链接错误
if ! flutter build linux --release; then
  echo "==> flutter build failed; retry verbose for linker details" >&2
  flutter build linux --release -v 2>&1 | tail -200 >&2 || true
  exit 1
fi

[[ -x "$BUNDLE/kotv" ]] || { echo "missing $BUNDLE/kotv" >&2; exit 1; }
cp -f "$ENGINE_OUT" "$BUNDLE/kotv-engine"
chmod +x "$BUNDLE/kotv-engine"
chmod +x "$ROOT/scripts/bundle-app-libmpv.sh"
"$ROOT/scripts/bundle-app-libmpv.sh" "$BUNDLE"
[[ -f "$BUNDLE/lib/libmpv.so.2" ]] || { echo "missing $BUNDLE/lib/libmpv.so.2" >&2; exit 1; }
# 与 macOS 同理：依赖须在 lib/ 旁，避免只靠系统 .so 或混载
find "$BUNDLE/lib" -maxdepth 1 -name 'libplacebo.so*' | grep -q . \
  || { echo "ERROR: missing libplacebo next to libmpv.so.2" >&2; exit 1; }
find "$BUNDLE/lib" -maxdepth 1 -name 'libass.so*' | grep -q . \
  || { echo "ERROR: missing libass next to libmpv.so.2" >&2; exit 1; }
[[ -d "$BUNDLE/runtime" ]] || { echo "missing $BUNDLE/runtime" >&2; exit 1; }
if [[ -f "$ROOT/cmd/updater/updater" ]]; then
  cp -f "$ROOT/cmd/updater/updater" "$BUNDLE/updater"
  chmod +x "$BUNDLE/updater"
fi
"$ROOT/scripts/verify-runtime.sh" "$BUNDLE/runtime" linux-x64

mkdir -p "$ROOT/dist"
rm -f "$OUT_ZIP"
(cd "$BUNDLE" && zip -r -q "$OUT_ZIP" .)
ls -lh "$OUT_ZIP"
