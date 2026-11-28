#!/usr/bin/env bash
# 将 DComp 补丁 Windows 引擎覆盖进当前 Flutter SDK cache。
# Win8+ 主线打包用；Win7（KOTV_WIN7=1）勿调用。
#
# 环境变量：
#   FLUTTER_ROOT / 当前 PATH 中的 flutter
#   KOTV_DCOMP_ENGINE_TAG   默认 windows-v3.47.1+2
#   KOTV_DCOMP_ENGINE_VER   默认 3.47.1（zip 内版本名）
#   KOTV_DCOMP_ENGINE_SHA256 可选；设置则校验 zip
set -euo pipefail

if [[ "${KOTV_WIN7:-}" == "1" ]]; then
  echo "skip DComp engine install (KOTV_WIN7=1)"
  exit 0
fi

TAG="${KOTV_DCOMP_ENGINE_TAG:-windows-v3.47.1+2}"
VER="${KOTV_DCOMP_ENGINE_VER:-3.47.1}"
# windows-v3.47.1+2 资产 SHA-256（发布页未贴时可留空跳过）
SHA256="${KOTV_DCOMP_ENGINE_SHA256:-}"

FLUTTER_BIN="$(command -v flutter || true)"
if [[ -z "$FLUTTER_BIN" ]]; then
  echo "ERROR: flutter not on PATH" >&2
  exit 1
fi
FLUTTER_SDK="$(cd "$(dirname "$FLUTTER_BIN")/.." && pwd)"
ENGINE_CACHE="$FLUTTER_SDK/bin/cache/artifacts/engine"
MARKER="$ENGINE_CACHE/kotv-dcomp-engine.marker"

echo "==> DComp engine: tag=$TAG ver=$VER sdk=$FLUTTER_SDK"

# 工具只认 engine.stamp 字符串；SDK 须为同系列（Win8+ x64/arm64 钉 3.47.1）。
STAMP_FILE="$FLUTTER_SDK/bin/internal/engine.version"
if [[ -f "$STAMP_FILE" ]]; then
  echo "    engine.version=$(tr -d '\r\n' < "$STAMP_FILE")"
fi

flutter precache --windows >/dev/null

TMP="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/kotv-dcomp-engine-$$"
mkdir -p "$TMP"
ZIP="$TMP/flutter-plezy-windows-${VER}.zip"
URL="https://github.com/edde746/flutter-plezy/releases/download/${TAG}/flutter-plezy-windows-${VER}.zip"
# tag 含 + 时 URL 需编码
URL_ENC="${URL//+/%2B}"

echo "==> download $URL_ENC"
curl -fsSL -o "$ZIP" "$URL_ENC"

if [[ -n "$SHA256" ]]; then
  if command -v shasum >/dev/null 2>&1; then
    echo "$SHA256  $ZIP" | shasum -a 256 -c -
  elif command -v sha256sum >/dev/null 2>&1; then
    echo "$SHA256  $ZIP" | sha256sum -c -
  fi
fi

echo "==> extract over $ENGINE_CACHE"
mkdir -p "$ENGINE_CACHE"
unzip -qo "$ZIP" -d "$TMP/out"
# zip 内为 windows-x64 / windows-x64-release（及 arm64 变体）
for dir in windows-x64 windows-x64-release windows-arm64 windows-arm64-release; do
  src="$TMP/out/$dir"
  if [[ -d "$src" ]]; then
    mkdir -p "$ENGINE_CACHE/$dir"
    cp -R "$src"/. "$ENGINE_CACHE/$dir"/
    echo "    installed $dir"
  fi
done

{
  echo "tag=$TAG"
  echo "ver=$VER"
  echo "installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "source=https://github.com/edde746/flutter-plezy"
  echo "license=BSD-3-Clause"
} >"$MARKER"
echo "==> marker $MARKER"
rm -rf "$TMP"
echo "ok DComp engine installed"
