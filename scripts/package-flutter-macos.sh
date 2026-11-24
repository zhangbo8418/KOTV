#!/usr/bin/env bash
# 打包 Flutter macOS：完整 runtime + Go 引擎 + UI → .app / .dmg
# 产物：dist/KO影视.app 、 dist/KO影视-{version}-{aarch64|x86_64}.dmg
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=kotv-release-name.sh
source "$ROOT/scripts/kotv-release-name.sh"
# shellcheck source=kotv-win-build-env.sh
source "$ROOT/scripts/kotv-win-build-env.sh"
export PATH="${HOME}/flutter/bin:${PATH}"
# 本地默认国内镜像；GitHub Actions 用官方源（镜像偶发 content-hash 失败）。
if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
  export PUB_HOSTED_URL="${PUB_HOSTED_URL:-https://pub.dev}"
  export FLUTTER_STORAGE_BASE_URL="${FLUTTER_STORAGE_BASE_URL:-https://storage.googleapis.com}"
  # shellcheck source=kotv-select-xcode.sh
  source "$ROOT/scripts/kotv-select-xcode.sh"
  kotv_select_newest_xcode
else
  export PUB_HOSTED_URL="${PUB_HOSTED_URL:-https://pub.flutter-io.cn}"
  export FLUTTER_STORAGE_BASE_URL="${FLUTTER_STORAGE_BASE_URL:-https://storage.flutter-io.cn}"
fi

# 优先显式平台参数（与 package.sh 一致）：./scripts/package-flutter-macos.sh macos-x64|macos-arm64
# 其次 KOTV_MACOS_FORCE_ARCH（CI 兼容）；否则跟 uname。
PLAT_ARG="${1:-}"
ARCH="$(uname -m)"
if [[ "$PLAT_ARG" == "macos-x64" || "$PLAT_ARG" == "macos-amd64" ]]; then
  ARCH=x86_64
elif [[ "$PLAT_ARG" == "macos-arm64" || "$PLAT_ARG" == "macos-aarch64" ]]; then
  ARCH=arm64
elif [[ -n "$PLAT_ARG" ]]; then
  echo "ERROR: unknown platform '$PLAT_ARG' (want macos-x64 or macos-arm64)" >&2
  exit 1
elif [[ "${KOTV_MACOS_FORCE_ARCH:-}" == "x86_64" || "${KOTV_MACOS_FORCE_ARCH:-}" == "amd64" ]]; then
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
kotv_check_version_literals "$VERSION"
REL_ARCH="$(kotv_release_arch "$PLAT")"
echo "==> version=$VERSION arch=$REL_ARCH ($PLAT) GOARCH=$GOARCH (uname=$(uname -m) arg=${PLAT_ARG:-} force=${KOTV_MACOS_FORCE_ARCH:-})"

chmod +x "$ROOT/scripts/"*.sh

export KOTV_MACOS_NO_FVP="${KOTV_MACOS_NO_FVP:-0}"
echo "==> KOTV_MACOS_NO_FVP=$KOTV_MACOS_NO_FVP"

echo "==> fetch desktop libmpv (AV3A source)"
"$ROOT/scripts/fetch-desktop-mpv-libs.sh"

# 仅有旧 jre 时也会跳过 prepare，导致猫爪 Node 缺失；jre 与 node 都要齐。
if [[ ! -d "$ROOT/runtime/jre" || ! -x "$ROOT/runtime/node/node" ]]; then
  echo "==> runtime incomplete (need jre + node), preparing..."
  "$ROOT/scripts/prepare-runtime.sh" "$PLAT"
fi

# 始终重编 bridge：Go 引擎已切 HTTP /health，旧 jar 的 --serve 仍是 stdin，会导致 connection refused。
echo "==> build spider-bridge.jar"
chmod +x "$ROOT/bridge/build.sh"
(cd "$ROOT" && ./bridge/build.sh)
mkdir -p "$ROOT/runtime/bridge"
cp -f "$ROOT/bridge/spider-bridge.jar" "$ROOT/runtime/bridge/spider-bridge.jar"

echo "==> build Go engine (GOARCH=$GOARCH)"
VER_LD="$(kotv_engine_version_ldflags "$VERSION")"
(cd "$ROOT" && CGO_ENABLED=1 GOOS=darwin GOARCH="$GOARCH" go generate ./internal/spider/ && CGO_ENABLED=1 GOOS=darwin GOARCH="$GOARCH" go build -ldflags "-s -w ${VER_LD}" -o "$ROOT/flutter/assets/engine/kotv-engine" ./cmd/engine)
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
# shellcheck source=kotv-flutter-asset-engines.sh
source "$ROOT/scripts/kotv-flutter-asset-engines.sh"
kotv_flutter_asset_engines_hide
trap kotv_flutter_asset_engines_restore EXIT
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
KOTV_FLUTTER_TARGET=macos "$ROOT/scripts/flutter-pub-get.sh"
if [[ "$KOTV_MACOS_NO_FVP" == "1" ]]; then
  "$ROOT/scripts/kotv-macos-exclude-fvp.sh"
  rm -rf "$ROOT/flutter/macos/Pods" "$ROOT/flutter/macos/Podfile.lock"
  (cd "$ROOT/flutter/macos" && KOTV_MACOS_NO_FVP=1 pod install)
  "$ROOT/scripts/kotv-macos-exclude-fvp.sh"
else
  kotv_ensure_mdk_apple_pod
fi
# 按目标架构限制 Xcode（通用二进制另一切片无对应 libmpv 时会绑到 Mpv.framework）。
if [[ "$ARCH" == "x86_64" ]]; then
  export ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO EXCLUDED_ARCHS=arm64
else
  export ARCHS=arm64 ONLY_ACTIVE_ARCH=NO EXCLUDED_ARCHS=x86_64
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
kotv_flutter_asset_engines_restore

STAGE="$ROOT/dist/_macos_dmg_stage"
OUT_APP="$ROOT/dist/KO影视.app"
DMG="$ROOT/dist/KO影视-${VERSION}-${REL_ARCH}.dmg"
rm -rf "$STAGE" "$OUT_APP" "$DMG"
mkdir -p "$ROOT/dist" "$STAGE"

echo "==> stage app from $APP_SRC"
ditto "$APP_SRC" "$OUT_APP"
while IFS= read -r assets_dir; do
  [[ -n "$assets_dir" ]] || continue
  kotv_flutter_strip_placeholder_assets "$assets_dir"
done < <(find "$OUT_APP" -type d -name flutter_assets)
# 双保险：若仍打出通用二进制，按目标架构瘦身，避免错误切片绑到 Mpv.framework。
PACK_MAIN="$OUT_APP/Contents/MacOS/KO影视"
[[ -x "$PACK_MAIN" ]] || PACK_MAIN="$OUT_APP/Contents/MacOS/kotv"
if [[ -x "$PACK_MAIN" ]] && lipo -info "$PACK_MAIN" 2>/dev/null | grep -q 'Architectures in the fat file'; then
  echo "==> lipo thin $PACK_MAIN -> $ARCH"
  lipo "$PACK_MAIN" -thin "$ARCH" -output "$PACK_MAIN.$ARCH"
  mv "$PACK_MAIN.$ARCH" "$PACK_MAIN"
  chmod +x "$PACK_MAIN"
fi

chmod +x "$ROOT/scripts/bundle-app-libmpv.sh"
"$ROOT/scripts/bundle-app-libmpv.sh" "$OUT_APP"

# 引擎只放 Resources/engine（launcher 优先找这里）。勿再拷进 MacOS，避免双份且易装错架构难查。
"$ROOT/scripts/bundle-flutter-runtime.sh" "$OUT_APP"
# 清理历史残留的 MacOS/kotv-engine
rm -f "$OUT_APP/Contents/MacOS/kotv-engine" "$OUT_APP/Contents/MacOS/kotv-engine.exe" 2>/dev/null || true

# 主程序必须是包内的 Mach-O。运行时目录和 Vulkan ICD 由 AppDelegate 按包路径设置。
MAIN_BIN="KO影视"
[[ -x "$OUT_APP/Contents/MacOS/$MAIN_BIN" ]] || MAIN_BIN="kotv"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $MAIN_BIN" "$OUT_APP/Contents/Info.plist" 2>/dev/null \
  || plutil -replace CFBundleExecutable -string "$MAIN_BIN" "$OUT_APP/Contents/Info.plist"

# 更新器在签名前放进包，避免签名之后再拷贝把密封弄坏。
if [[ -f "$ROOT/dist/updater-mac/updater" ]]; then
  cp -f "$ROOT/dist/updater-mac/updater" "$OUT_APP/Contents/MacOS/updater"
  chmod +x "$OUT_APP/Contents/MacOS/updater"
fi

echo "==> verify package"
test -x "$OUT_APP/Contents/Resources/runtime/jre/bin/java"
test -x "$OUT_APP/Contents/Resources/runtime/node/node"
test -e "$OUT_APP/Contents/Resources/runtime/bridge/spider-bridge.jar" \
  || test -e "$OUT_APP/Contents/Resources/runtime/bridge"
test -x "$OUT_APP/Contents/Resources/engine/kotv-engine"
kotv_flutter_asset_engines_reject "$OUT_APP"
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
test -e "$OUT_APP/Contents/Frameworks/libmpv.2.dylib" \
  || { echo "ERROR: missing Frameworks/libmpv.2.dylib (主程序 -lmpv 依赖此名)" >&2; exit 1; }
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
# 随包库的最低系统不得高于应用本身，否则旧系统启动即被 dyld 杀掉（Symbol not found）。
MIN_OS="$(kotv_macos_deployment_target)"
TOO_NEW="$(find "$OUT_APP/Contents/Frameworks" "$OUT_APP/Contents/MacOS" -type f \( -name '*.dylib' -o -perm -u+x \) -print0 \
  | xargs -0 -I{} sh -c 'm=$(otool -l "$1" 2>/dev/null | awk "/LC_BUILD_VERSION/{f=1} f&&\$1==\"minos\"{print \$2; exit}"); [ -n "$m" ] && printf "%s %s\n" "$m" "$1"' _ {} \
  | awk -v want="$MIN_OS" '{ split($1,a,"."); split(want,b,"."); if (a[1]+0 > b[1]+0 || (a[1]+0 == b[1]+0 && a[2]+0 > b[2]+0)) print }')"
if [[ -n "$TOO_NEW" ]]; then
  echo "ERROR: bundled Mach-O requires newer macOS than $MIN_OS:" >&2
  echo "$TOO_NEW" >&2
  exit 1
fi
if ! find "$OUT_APP/Contents/Frameworks" -maxdepth 1 \( -name 'libplacebo.*.dylib' -o -name 'libplacebo.dylib' \) | grep -q .; then
  echo "ERROR: missing bundled libplacebo in Frameworks" >&2
  exit 1
fi
if strings "$OUT_APP/Contents/Frameworks/libmpv.dylib" | grep -q 'AVFFrameReceiver'; then
  echo "ERROR: bundled libmpv still contains AVFFrameReceiver" >&2
  exit 1
fi
if ! grep -aFq 'vo_avfoundation' "$OUT_APP/Contents/Frameworks/libmpv.dylib"; then
  echo "ERROR: bundled libmpv missing vo_avfoundation" >&2
  exit 1
fi
# Runner 必须把 mpv_* 绑到自带 libmpv（带 avfoundation VO）。通用二进制按打包架构检查。
PACK_BIN="$OUT_APP/Contents/MacOS/KO影视"
MPV_BIND="$(nm -m "$PACK_BIN" 2>/dev/null | grep '_mpv_create' | head -1 || true)"
if ! echo "$MPV_BIND" | grep -q '(from libmpv)'; then
  echo "ERROR: main binary ($ARCH) mpv_create not bound to libmpv (got: ${MPV_BIND:-empty})" >&2
  echo "hint: OTHER_LDFLAGS must list -lmpv before \$(inherited) / Mpv.framework" >&2
  exit 1
fi
if echo "$MPV_BIND" | grep -q '(from Mpv)'; then
  echo "ERROR: main binary ($ARCH) still binds mpv_create to Mpv.framework: $MPV_BIND" >&2
  exit 1
fi
echo "  java ok, engine ok, libmpv ok (self-contained, vo_avfoundation, $ARCH bind=$MPV_BIND)"

echo "==> ad-hoc sign"
codesign --force --deep --sign - "$OUT_APP"

echo "==> make dmg"
ditto "$OUT_APP" "$STAGE/KO影视.app"
ln -sf /Applications "$STAGE/Applications"
hdiutil create -volname "KO影视" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

echo "app: $OUT_APP"
echo "dmg: $DMG"
ls -lh "$DMG"
du -sh "$OUT_APP" "$OUT_APP/Contents/Resources/runtime"
