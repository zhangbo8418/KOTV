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
"$ROOT/scripts/prepare-runtime.sh" linux-x64
"$ROOT/scripts/verify-runtime.sh" runtime linux-x64

echo "==> build Go engine"
(cd "$ROOT/internal/spider" && go run gen_qjsinc.go)
(cd "$ROOT" && CGO_ENABLED=1 go build -ldflags "-s -w" -o "$ENGINE_OUT" ./cmd/engine)
chmod +x "$ENGINE_OUT"

echo "==> flutter build linux --release"
cd "$ROOT/flutter"
flutter config --enable-linux-desktop
flutter pub get
flutter build linux --release

[[ -x "$BUNDLE/kotv" ]] || { echo "missing $BUNDLE/kotv" >&2; exit 1; }
cp -f "$ENGINE_OUT" "$BUNDLE/kotv-engine"
chmod +x "$BUNDLE/kotv-engine"
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
