#!/usr/bin/env bash
# CI：确保 PATH 上有可用的 Flutter（arm64 runner 常无预编译 SDK 包，改 git clone）。
# 用法: FLUTTER_VERSION=3.47.1 ./scripts/ci-ensure-flutter.sh
# 成功后把 flutter/bin 追加到 $GITHUB_PATH（若在 Actions 中）。
set -euo pipefail

VER="${FLUTTER_VERSION:?set FLUTTER_VERSION}"
DEST="${KOTV_FLUTTER_HOME:-${RUNNER_TEMP:-/tmp}/flutter-${VER}}"

if command -v flutter >/dev/null 2>&1; then
  echo "flutter already on PATH: $(command -v flutter)"
  flutter --version || true
  exit 0
fi

if [[ -x "$DEST/bin/flutter" ]]; then
  echo "reuse $DEST"
else
  echo "==> clone flutter $VER → $DEST"
  rm -rf "$DEST"
  git clone --depth 1 --branch "$VER" https://github.com/flutter/flutter.git "$DEST"
fi

echo "${DEST}/bin" >>"${GITHUB_PATH:-/dev/null}"
export PATH="${DEST}/bin:$PATH"
flutter --version
flutter precache --no-android --no-ios || flutter precache || true
echo "FLUTTER_ROOT=$DEST"
