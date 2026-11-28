#!/usr/bin/env bash
# 将 DComp 补丁 Windows 引擎覆盖进当前 Flutter SDK cache。
# Win8+（x64 / arm64）打包用；Win7（KOTV_WIN7=1）跳过。
# 版本默认见 kotv-flutter-pins.sh；CI / 本地均可只调本脚本（勿在 CI 再复制一套步骤）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=kotv-flutter-pins.sh
source "$ROOT/scripts/kotv-flutter-pins.sh"

if [[ "${KOTV_WIN7:-}" == "1" ]]; then
  echo "skip DComp engine install (KOTV_WIN7=1)"
  exit 0
fi

TAG="$KOTV_DCOMP_ENGINE_TAG"
VER="$KOTV_DCOMP_ENGINE_VER"
SHA256="${KOTV_DCOMP_ENGINE_SHA256:-}"
URL_BASE="$KOTV_DCOMP_ENGINE_URL_BASE"

FLUTTER_BIN="$(command -v flutter || true)"
if [[ -z "$FLUTTER_BIN" ]]; then
  echo "ERROR: flutter not on PATH" >&2
  exit 1
fi
FLUTTER_SDK="$(cd "$(dirname "$FLUTTER_BIN")/.." && pwd)"
ENGINE_CACHE="$FLUTTER_SDK/bin/cache/artifacts/engine"
MARKER="$ENGINE_CACHE/kotv-dcomp-engine.marker"

# 已装且 stamp 一致则跳过（CI 与 package 脚本共用本入口时不会重复下载）。
if [[ -f "$MARKER" ]] \
  && grep -qx "tag=$TAG" "$MARKER" \
  && grep -qx "ver=$VER" "$MARKER"; then
  echo "ok DComp engine already installed (tag=$TAG ver=$VER)"
  exit 0
fi

echo "==> DComp engine: tag=$TAG ver=$VER sdk=$FLUTTER_SDK"
# SDK 须与制品同系列（见 FLUTTER_WINDOWS_VERSION / kotv-flutter-pins.sh）。
STAMP_FILE="$FLUTTER_SDK/bin/internal/engine.version"
if [[ -f "$STAMP_FILE" ]]; then
  echo "    engine.version=$(tr -d '\r\n' < "$STAMP_FILE")"
fi

flutter precache --windows >/dev/null

TMP="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/kotv-dcomp-engine-$$"
mkdir -p "$TMP"
ZIP="$TMP/dcomp-windows-${VER}.zip"
URL="${URL_BASE}/${TAG}/flutter-plezy-windows-${VER}.zip"
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
installed=0
for dir in windows-x64 windows-x64-release windows-arm64 windows-arm64-release; do
  src="$TMP/out/$dir"
  if [[ -d "$src" ]]; then
    mkdir -p "$ENGINE_CACHE/$dir"
    cp -R "$src"/. "$ENGINE_CACHE/$dir"/
    echo "    installed $dir"
    installed=1
  fi
done
if [[ "$installed" -ne 1 ]]; then
  echo "ERROR: DComp zip had no windows-x64/arm64 engine dirs" >&2
  exit 1
fi

{
  echo "tag=$TAG"
  echo "ver=$VER"
  echo "installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "source=${URL_BASE}"
  echo "license=BSD-3-Clause"
} >"$MARKER"
echo "==> marker $MARKER"
rm -rf "$TMP"
echo "ok DComp engine installed"
