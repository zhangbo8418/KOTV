#!/usr/bin/env bash
# 打包 Flutter macOS：完整 runtime + Go 引擎 + UI → .app / .dmg
# 产物：dist/KO影视.app 、 dist/KO影视-{version}-{aarch64|x86_64}.dmg
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=kotv-release-name.sh
source "$ROOT/scripts/kotv-release-name.sh"
export PATH="${HOME}/flutter/bin:${PATH}"
export PUB_HOSTED_URL="${PUB_HOSTED_URL:-https://pub.flutter-io.cn}"
export FLUTTER_STORAGE_BASE_URL="${FLUTTER_STORAGE_BASE_URL:-https://storage.flutter-io.cn}"

ARCH="$(uname -m)"
PLAT="macos-x64"
[[ "$ARCH" == "arm64" ]] && PLAT="macos-arm64"
VERSION="$(kotv_release_version "$ROOT/flutter/pubspec.yaml")"
REL_ARCH="$(kotv_release_arch "$PLAT")"
echo "==> version=$VERSION arch=$REL_ARCH ($PLAT)"

chmod +x "$ROOT/scripts/"*.sh

if [[ ! -d "$ROOT/runtime/jre" ]]; then
  echo "==> runtime incomplete, preparing..."
  "$ROOT/scripts/prepare-runtime.sh" "$PLAT"
fi

# 始终重编 bridge：Go 引擎已切 HTTP /health，旧 jar 的 --serve 仍是 stdin，会导致 connection refused。
echo "==> build spider-bridge.jar"
chmod +x "$ROOT/bridge/build.sh"
(cd "$ROOT" && ./bridge/build.sh)
mkdir -p "$ROOT/runtime/bridge"
cp -f "$ROOT/bridge/spider-bridge.jar" "$ROOT/runtime/bridge/spider-bridge.jar"

echo "==> build Go engine"
(cd "$ROOT" && CGO_ENABLED=1 go generate ./internal/spider/ && CGO_ENABLED=1 go build -o "$ROOT/flutter/assets/engine/kotv-engine" ./cmd/engine)
chmod +x "$ROOT/flutter/assets/engine/kotv-engine"
cp -f "$ROOT/flutter/assets/engine/kotv-engine" /tmp/kotv-engine
ENG_SZ="$(wc -c < "$ROOT/flutter/assets/engine/kotv-engine" | tr -d ' ')"
ENG_SHA="$(shasum -a 256 "$ROOT/flutter/assets/engine/kotv-engine" | awk '{print $1}')"
echo "  ok: engine -> $ROOT/flutter/assets/engine/kotv-engine ($ENG_SZ bytes, sha256=$ENG_SHA)"
file "$ROOT/flutter/assets/engine/kotv-engine"

echo "==> flutter build macos --release"
cd "$ROOT/flutter"
rm -rf \
  "$ROOT/flutter/build/macos/Build/Products/Release/KO影视.app" \
  "$ROOT/flutter/build/macos/Build/Products/Release/kotv.app" \
  2>/dev/null || true
# 双保险：pubspec 已关 SPM，CI 全局再关一次
flutter config --no-enable-swift-package-manager || true
# fvp 依赖 mdk；优先用预解压的本地 pod，避免 CocoaPods 卡在 SourceForge。
# shellcheck source=kotv-fvp-deps.sh
source "$ROOT/scripts/kotv-fvp-deps.sh"
kotv_export_fvp_deps
kotv_ensure_mdk_apple_pod
flutter pub get
flutter build macos --release

APP_SRC=""
for cand in \
  "$ROOT/flutter/build/macos/Build/Products/Release/KO影视.app" \
  "$ROOT/flutter/build/macos/Build/Products/Release/kotv.app"
do
  if [[ -d "$cand" ]]; then
    APP_SRC="$cand"
    break
  fi
done
[[ -n "$APP_SRC" ]] || { echo "missing Release .app under build/macos/..." >&2; exit 1; }

STAGE="$ROOT/dist/_macos_dmg_stage"
OUT_APP="$ROOT/dist/KO影视.app"
DMG="$ROOT/dist/KO影视-${VERSION}-${REL_ARCH}.dmg"
rm -rf "$STAGE" "$OUT_APP" "$DMG"
mkdir -p "$ROOT/dist" "$STAGE"

echo "==> stage app from $APP_SRC"
ditto "$APP_SRC" "$OUT_APP"

KOTV_BUNDLE_ENGINE_TO_MACOS=1 "$ROOT/scripts/bundle-flutter-runtime.sh" "$OUT_APP"

WRAP="$OUT_APP/Contents/MacOS/kotv-launch"
MAIN_BIN="KO影视"
[[ -x "$OUT_APP/Contents/MacOS/$MAIN_BIN" ]] || MAIN_BIN="kotv"
cat > "$WRAP" <<EOF
#!/bin/bash
DIR="\$(cd "\$(dirname "\$0")" && pwd)"
if [[ -z "\${KOTV_RUNTIME:-}" && -d "\$DIR/../Resources/runtime" ]]; then
  export KOTV_RUNTIME="\$DIR/../Resources/runtime"
fi
exec "\$DIR/$MAIN_BIN" "\$@"
EOF
chmod +x "$WRAP"

/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable kotv-launch" "$OUT_APP/Contents/Info.plist" 2>/dev/null \
  || plutil -replace CFBundleExecutable -string kotv-launch "$OUT_APP/Contents/Info.plist"

echo "==> verify package"
test -x "$OUT_APP/Contents/Resources/runtime/jre/bin/java"
test -e "$OUT_APP/Contents/Resources/runtime/bridge/spider-bridge.jar" \
  || test -e "$OUT_APP/Contents/Resources/runtime/bridge"
test -x "$OUT_APP/Contents/MacOS/kotv-engine" \
  || test -x "$OUT_APP/Contents/Resources/engine/kotv-engine"
echo "  java ok, engine ok"

echo "==> ad-hoc sign"
codesign --force --deep --sign - "$OUT_APP" 2>/dev/null || true

echo "==> make dmg"
ditto "$OUT_APP" "$STAGE/KO影视.app"
ln -sf /Applications "$STAGE/Applications"
hdiutil create -volname "KO影视" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

echo "app: $OUT_APP"
echo "dmg: $DMG"
ls -lh "$DMG"
du -sh "$OUT_APP" "$OUT_APP/Contents/Resources/runtime"
