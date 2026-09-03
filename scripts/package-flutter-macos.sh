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
# CI 可钉死：KOTV_MACOS_FORCE_ARCH=x86_64|arm64（避免 Rosetta 下 uname 偶发仍报 arm64）
if [[ "${KOTV_MACOS_FORCE_ARCH:-}" == "x86_64" || "${KOTV_MACOS_FORCE_ARCH:-}" == "amd64" ]]; then
  ARCH=x86_64
elif [[ "${KOTV_MACOS_FORCE_ARCH:-}" == "arm64" || "${KOTV_MACOS_FORCE_ARCH:-}" == "aarch64" ]]; then
  ARCH=arm64
fi
PLAT="macos-x64"
[[ "$ARCH" == "arm64" ]] && PLAT="macos-arm64"
# 显式钉死 Go 引擎架构，避免 Rosetta/交叉环境下编出与包名不符的二进制。
if [[ "$PLAT" == "macos-arm64" ]]; then
  export GOARCH=arm64
  export GOOS=darwin
  WANT_ENGINE_ARCH=arm64
else
  export GOARCH=amd64
  export GOOS=darwin
  WANT_ENGINE_ARCH=x86_64
fi
VERSION="$(kotv_release_version "$ROOT/flutter/pubspec.yaml")"
REL_ARCH="$(kotv_release_arch "$PLAT")"
echo "==> version=$VERSION arch=$REL_ARCH ($PLAT) GOARCH=$GOARCH (uname=$(uname -m) force=${KOTV_MACOS_FORCE_ARCH:-})"

chmod +x "$ROOT/scripts/"*.sh

export KOTV_MACOS_NO_FVP="${KOTV_MACOS_NO_FVP:-0}"
echo "==> KOTV_MACOS_NO_FVP=$KOTV_MACOS_NO_FVP"

echo "==> fetch desktop libmpv (AV3A source)"
"$ROOT/scripts/fetch-desktop-mpv-libs.sh"

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

echo "==> build Go engine (GOARCH=$GOARCH)"
(cd "$ROOT" && CGO_ENABLED=1 GOOS=darwin GOARCH="$GOARCH" go generate ./internal/spider/ && CGO_ENABLED=1 GOOS=darwin GOARCH="$GOARCH" go build -o "$ROOT/flutter/assets/engine/kotv-engine" ./cmd/engine)
chmod +x "$ROOT/flutter/assets/engine/kotv-engine"
ENG_SZ="$(wc -c < "$ROOT/flutter/assets/engine/kotv-engine" | tr -d ' ')"
ENG_SHA="$(shasum -a 256 "$ROOT/flutter/assets/engine/kotv-engine" | awk '{print $1}')"
echo "  ok: engine -> $ROOT/flutter/assets/engine/kotv-engine ($ENG_SZ bytes, sha256=$ENG_SHA)"
file "$ROOT/flutter/assets/engine/kotv-engine"
ENG_FILE_ARCH="$(file -b "$ROOT/flutter/assets/engine/kotv-engine")"
if ! echo "$ENG_FILE_ARCH" | grep -q "$WANT_ENGINE_ARCH"; then
  echo "ERROR: kotv-engine arch mismatch: want $WANT_ENGINE_ARCH, got: $ENG_FILE_ARCH" >&2
  exit 1
fi

echo "==> flutter build macos --release (KOTV_MACOS_NO_FVP=$KOTV_MACOS_NO_FVP)"
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
"$ROOT/scripts/flutter-pub-get.sh"
if [[ "$KOTV_MACOS_NO_FVP" == "1" ]]; then
  "$ROOT/scripts/kotv-macos-exclude-fvp.sh"
  rm -rf "$ROOT/flutter/macos/Pods" "$ROOT/flutter/macos/Podfile.lock"
  (cd "$ROOT/flutter/macos" && KOTV_MACOS_NO_FVP=1 pod install)
  "$ROOT/scripts/kotv-macos-exclude-fvp.sh"
else
  kotv_ensure_mdk_apple_pod
fi
flutter build macos --release \
  --dart-define=KOTV_MACOS_NO_FVP=$KOTV_MACOS_NO_FVP

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

chmod +x "$ROOT/scripts/bundle-app-libmpv.sh"
"$ROOT/scripts/bundle-app-libmpv.sh" "$OUT_APP"

# 引擎只放 Resources/engine（launcher 优先找这里）。勿再拷进 MacOS，避免双份且易装错架构难查。
"$ROOT/scripts/bundle-flutter-runtime.sh" "$OUT_APP"
# 清理历史残留的 MacOS/kotv-engine
rm -f "$OUT_APP/Contents/MacOS/kotv-engine" "$OUT_APP/Contents/MacOS/kotv-engine.exe" 2>/dev/null || true

WRAP="$OUT_APP/Contents/MacOS/kotv-launch"
MAIN_BIN="KO影视"
[[ -x "$OUT_APP/Contents/MacOS/$MAIN_BIN" ]] || MAIN_BIN="kotv"
cat > "$WRAP" <<EOF
#!/bin/bash
DIR="\$(cd "\$(dirname "\$0")" && pwd)"
if [[ -z "\${KOTV_RUNTIME:-}" && -d "\$DIR/../Resources/runtime" ]]; then
  export KOTV_RUNTIME="\$DIR/../Resources/runtime"
fi
# 自带 MoltenVK ICD（与 Frameworks/libMoltenVK.dylib 配套）
ICD="\$DIR/../Resources/vulkan/icd.d/MoltenVK_icd.json"
if [[ -f "\$ICD" ]]; then
  export VK_ICD_FILENAMES="\$ICD\${VK_ICD_FILENAMES:+:\$VK_ICD_FILENAMES}"
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
test -x "$OUT_APP/Contents/Resources/engine/kotv-engine"
# 禁止再出现双引擎；MacOS 下不应有 kotv-engine
if [[ -e "$OUT_APP/Contents/MacOS/kotv-engine" || -e "$OUT_APP/Contents/MacOS/kotv-engine.exe" ]]; then
  echo "ERROR: duplicate engine under Contents/MacOS (keep only Resources/engine)" >&2
  exit 1
fi
PACK_ENG_ARCH="$(file -b "$OUT_APP/Contents/Resources/engine/kotv-engine")"
if ! echo "$PACK_ENG_ARCH" | grep -q "$WANT_ENGINE_ARCH"; then
  echo "ERROR: packaged kotv-engine arch mismatch: want $WANT_ENGINE_ARCH, got: $PACK_ENG_ARCH" >&2
  exit 1
fi
test -f "$OUT_APP/Contents/Frameworks/libmpv.dylib"
# 发行包不得再链 Homebrew 绝对路径，且 LC_RPATH 不得指向 Cellar（否则会混载两套库 SIGABRT）。
if otool -L "$OUT_APP/Contents/Frameworks/libmpv.dylib" | awk 'NR>1 {print $1}' | grep -E '^(/usr/local/|/opt/homebrew/)'; then
  echo "ERROR: Frameworks/libmpv.dylib still has Homebrew absolute deps" >&2
  otool -L "$OUT_APP/Contents/Frameworks/libmpv.dylib" | head -40 >&2
  exit 1
fi
if otool -l "$OUT_APP/Contents/Frameworks/libmpv.dylib" | awk '
  $1 == "cmd" && $2 == "LC_RPATH" { want = 1; next }
  want && $1 == "cmdsize" { next }
  want && $1 == "path" { print $2; want = 0 }
' | grep -E '^(/usr/local/|/opt/homebrew/|/Users/|/Applications/Xcode)'; then
  echo "ERROR: Frameworks/libmpv.dylib still has absolute LC_RPATH (Homebrew/Xcode)" >&2
  otool -l "$OUT_APP/Contents/Frameworks/libmpv.dylib" | awk '
    $1 == "cmd" && $2 == "LC_RPATH" { want = 1; next }
    want && $1 == "cmdsize" { next }
    want && $1 == "path" { print $2; want = 0 }
  ' >&2
  exit 1
fi
test -f "$OUT_APP/Contents/Frameworks/libplacebo.360.dylib" \
  || test -f "$OUT_APP/Contents/Frameworks/libplacebo.dylib" \
  || { echo "ERROR: missing bundled libplacebo in Frameworks" >&2; exit 1; }
if strings "$OUT_APP/Contents/Frameworks/libmpv.dylib" | grep -q 'AVFFrameReceiver'; then
  echo "ERROR: bundled libmpv still contains AVFFrameReceiver" >&2
  exit 1
fi
echo "  java ok, engine ok, libmpv ok (self-contained)"

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
