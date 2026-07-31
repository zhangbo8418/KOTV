#!/usr/bin/env bash
# 打包 Flutter macOS：完整 runtime（jre/python/…）+ Go 引擎 + UI → .app / .dmg
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="${HOME}/flutter/bin:${PATH}"
export PUB_HOSTED_URL="${PUB_HOSTED_URL:-https://pub.flutter-io.cn}"
export FLUTTER_STORAGE_BASE_URL="${FLUTTER_STORAGE_BASE_URL:-https://storage.flutter-io.cn}"

ARCH="$(uname -m)"
PLAT="macos-x64"
[[ "$ARCH" == "arm64" ]] && PLAT="macos-arm64"

if [[ ! -d "$ROOT/runtime/jre" || ! -d "$ROOT/runtime/libvlc" ]]; then
  echo "==> runtime incomplete, preparing..."
  "$ROOT/scripts/prepare-runtime.sh" "$PLAT"
fi

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
# 清掉可能残留在 MacOS 的未签名引擎，避免 Xcode CodeSign 失败
rm -rf \
  "$ROOT/flutter/build/macos/Build/Products/Release/KO影视.app" \
  "$ROOT/flutter/build/macos/Build/Products/Release/kotv.app" \
  2>/dev/null || true
flutter pub get
flutter build macos --release

# PRODUCT_NAME = KO影视
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

STAGE="$ROOT/dist/_flutter_dmg_stage"
OUT_APP="$ROOT/dist/KO影视-Flutter.app"
DMG="$ROOT/dist/KO影视-Flutter-${PLAT}.dmg"
rm -rf "$STAGE" "$OUT_APP" "$DMG"
mkdir -p "$ROOT/dist" "$STAGE"

echo "==> stage app from $APP_SRC"
ditto "$APP_SRC" "$OUT_APP"

# 完整 runtime + 引擎（Xcode Build Phase 已拷 Resources；这里再保证发行包齐全，并放入 MacOS 供启动脚本）
KOTV_BUNDLE_ENGINE_TO_MACOS=1 "$ROOT/scripts/bundle-flutter-runtime.sh" "$OUT_APP"

# 启动包装：只注入 KOTV_RUNTIME；引擎由 Flutter 托管（随窗口关闭）
WRAP="$OUT_APP/Contents/MacOS/kotv-launch"
# 主可执行名与 PRODUCT_NAME 一致
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
test -e "$OUT_APP/Contents/Resources/runtime/libvlc"
test -e "$OUT_APP/Contents/Resources/runtime/bridge/spider-bridge.jar" \
  || test -e "$OUT_APP/Contents/Resources/runtime/bridge"
test -x "$OUT_APP/Contents/MacOS/kotv-engine" \
  || test -x "$OUT_APP/Contents/Resources/engine/kotv-engine"
echo "  java ok, libvlc ok, engine ok"

echo "==> ad-hoc sign"
codesign --force --deep --sign - "$OUT_APP" 2>/dev/null || true

echo "==> make dmg"
ditto "$OUT_APP" "$STAGE/KO影视-Flutter.app"
ln -sf /Applications "$STAGE/Applications"
hdiutil create -volname "KO影视 Flutter" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

echo "app: $OUT_APP"
echo "dmg: $DMG"
ls -lh "$DMG"
du -sh "$OUT_APP" "$OUT_APP/Contents/Resources/runtime"
