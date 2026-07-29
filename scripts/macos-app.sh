#!/usr/bin/env bash
# 组装 macOS .app + DMG（显示名 KO影视，可执行文件仍为 KOTV）
# 用法: ./scripts/macos-app.sh <platform> <dist-dir>
# 例如: ./scripts/macos-app.sh macos-x64 dist/KOTV-macos-x64
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLAT="${1:?platform}"
SRC="${2:?dist dir with KOTV binary + runtime}"
VERSION="${KOTV_VERSION:-${VERSION:-0.1.0}}"
VERSION="${VERSION#v}"

case "$PLAT" in
  macos-arm64|macos-x64) ;;
  *) echo "macos-app.sh only for macos-*; got $PLAT" >&2; exit 1 ;;
esac

BIN="$SRC/KOTV"
[[ -x "$BIN" ]] || { echo "missing binary: $BIN" >&2; exit 1; }
[[ -d "$SRC/runtime" ]] || { echo "missing runtime: $SRC/runtime" >&2; exit 1; }

"$ROOT/scripts/verify-runtime.sh" "$SRC/runtime" "$PLAT"

OUT_APP="$ROOT/dist/KO影视.app"
DMG="$ROOT/dist/KO影视-${PLAT}.dmg"
STAGE="$ROOT/dist/_dmg_stage_${PLAT}"

rm -rf "$OUT_APP" "$STAGE" "$DMG"
mkdir -p "$OUT_APP/Contents/MacOS" "$OUT_APP/Contents/Resources"

cp "$BIN" "$OUT_APP/Contents/MacOS/KOTV"
chmod +x "$OUT_APP/Contents/MacOS/KOTV"
cp "$ROOT/resources/icons/KOTV.icns" "$OUT_APP/Contents/Resources/AppIcon.icns"

# 完整拷贝 runtime（ditto 保留 dylib/symlink，避免缺 jre/lib）
mkdir -p "$OUT_APP/Contents/Resources/runtime"
ditto "$SRC/runtime" "$OUT_APP/Contents/Resources/runtime"
# 再剥一次（若上游未 strip 也兜底）
"$ROOT/scripts/strip-runtime-launchers.sh" "$OUT_APP/Contents/Resources/runtime"

# updater（可选）
if [[ -f "$SRC/updater" ]]; then
  cp "$SRC/updater" "$OUT_APP/Contents/MacOS/updater"
  chmod +x "$OUT_APP/Contents/MacOS/updater"
fi

cat > "$OUT_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>zh_CN</string>
	<key>CFBundleExecutable</key>
	<string>KOTV</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>com.bobo.kotv</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>KO影视</string>
	<key>CFBundleDisplayName</key>
	<string>KO影视</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${VERSION}</string>
	<key>LSMinimumSystemVersion</key>
	<string>11.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
PLIST

KOTV_EXPECT_EMBED_STRIP=1 "$ROOT/scripts/verify-runtime.sh" "$OUT_APP/Contents/Resources/runtime" "$PLAT"
xattr -cr "$OUT_APP" 2>/dev/null || true

# DMG：仅 KO影视.app + Applications（系统里看到的名字来自 .app 名 / DisplayName）
mkdir -p "$STAGE"
ditto "$OUT_APP" "$STAGE/KO影视.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "KO影视" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

echo "app: $OUT_APP"
echo "dmg: $DMG"
ls -lh "$DMG"
