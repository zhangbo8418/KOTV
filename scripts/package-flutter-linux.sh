#!/usr/bin/env bash
# 打包 Flutter Linux：runtime + Go 引擎 + UI → ZIP
# 用法: ./scripts/package-flutter-linux.sh [linux-x64|linux-arm64]
# 产物：dist/KO影视-{ver}-linux-{x86_64|aarch64}.zip
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=kotv-release-name.sh
source "$ROOT/scripts/kotv-release-name.sh"
# shellcheck source=kotv-win-build-env.sh
source "$ROOT/scripts/kotv-win-build-env.sh"
export PATH="${HOME}/flutter/bin:${PATH}"

# 无参跟宿主 arch（勿默认 linux-x64：aarch64 本机会编出 amd64 引擎 + arm64 Flutter 混包）。
PLAT="${1:-$(kotv_detect_host_plat)}"
case "$PLAT" in
  linux-x64) FLUTTER_LINUX_ARCH=x64; GOARCH_LINUX=amd64 ;;
  linux-arm64) FLUTTER_LINUX_ARCH=arm64; GOARCH_LINUX=arm64 ;;
  *) echo "usage: $0 [linux-x64|linux-arm64]" >&2; exit 1 ;;
esac

VERSION="$(kotv_release_version "$ROOT/flutter/pubspec.yaml")"
kotv_check_version_literals "$VERSION"
REL_ARCH="$(kotv_release_arch "$PLAT")"
OUT_ZIP="$ROOT/dist/KO影视-${VERSION}-linux-${REL_ARCH}.zip"
ENGINE_OUT="$ROOT/flutter/assets/engine/kotv-engine"
BUNDLE="$ROOT/flutter/build/linux/${FLUTTER_LINUX_ARCH}/release/bundle"

echo "==> Flutter Linux package version=$VERSION plat=$PLAT"

chmod +x "$ROOT/bridge/build.sh" "$ROOT"/scripts/*.sh
echo "==> fetch desktop libmpv (AV3A source)"
export KOTV_FETCH_DESKTOP_PLAT=linux
"$ROOT/scripts/fetch-desktop-mpv-libs.sh"
"$ROOT/scripts/prepare-runtime.sh" "$PLAT"
"$ROOT/scripts/verify-runtime.sh" runtime "$PLAT"

echo "==> build Go engine"
(cd "$ROOT/internal/spider" && go run gen_qjsinc.go)
export GOPROXY="${GOPROXY:-https://proxy.golang.org,direct}"
ok_eng=0
for attempt in 1 2 3; do
  VER_LD="$(kotv_engine_version_ldflags "$VERSION")"
  if (cd "$ROOT" && CGO_ENABLED=1 GOARCH="$GOARCH_LINUX" go build -ldflags "-s -w ${VER_LD}" -o "$ENGINE_OUT" ./cmd/engine); then
    ok_eng=1
    break
  fi
  echo "WARN: go build engine failed (attempt $attempt); retry..." >&2
  sleep $((attempt * 5))
done
[[ "$ok_eng" == 1 ]] || { echo "ERROR: go build engine failed after retries" >&2; exit 1; }
chmod +x "$ENGINE_OUT"

echo "==> flutter build linux --release"
# shellcheck source=kotv-flutter-asset-engines.sh
source "$ROOT/scripts/kotv-flutter-asset-engines.sh"
kotv_flutter_asset_engines_hide
trap kotv_flutter_asset_engines_restore EXIT
cd "$ROOT/flutter"
# shellcheck source=kotv-fvp-deps.sh
source "$ROOT/scripts/kotv-fvp-deps.sh"
kotv_export_fvp_deps
flutter config --enable-linux-desktop
KOTV_FLUTTER_TARGET=linux "$ROOT/scripts/flutter-pub-get.sh"
unset CMAKE_GENERATOR CMAKE_TOOLCHAIN_FILE CMAKE_C_COMPILER CMAKE_CXX_COMPILER || true
if ! flutter build linux --release; then
  echo "==> flutter build failed; retry verbose for linker details" >&2
  flutter build linux --release -v 2>&1 | tail -200 >&2 || true
  exit 1
fi

[[ -x "$BUNDLE/kotv" ]] || { echo "missing $BUNDLE/kotv" >&2; exit 1; }
kotv_flutter_asset_engines_restore
cp -f "$ENGINE_OUT" "$BUNDLE/kotv-engine"
chmod +x "$BUNDLE/kotv-engine"
chmod +x "$ROOT/scripts/bundle-app-libmpv.sh"
"$ROOT/scripts/bundle-app-libmpv.sh" "$BUNDLE"
[[ -f "$BUNDLE/lib/libmpv.so.2" ]] || { echo "missing $BUNDLE/lib/libmpv.so.2" >&2; exit 1; }
find "$BUNDLE/lib" -maxdepth 1 -name 'libplacebo.so*' | grep -q . \
  || { echo "ERROR: missing libplacebo next to libmpv.so.2" >&2; exit 1; }
find "$BUNDLE/lib" -maxdepth 1 -name 'libass.so*' | grep -q . \
  || { echo "ERROR: missing libass next to libmpv.so.2" >&2; exit 1; }
[[ -d "$BUNDLE/runtime" ]] || { echo "missing $BUNDLE/runtime" >&2; exit 1; }
if [[ -f "$ROOT/cmd/updater/updater" ]]; then
  cp -f "$ROOT/cmd/updater/updater" "$BUNDLE/updater"
  chmod +x "$BUNDLE/updater"
fi
"$ROOT/scripts/verify-runtime.sh" "$BUNDLE/runtime" "$PLAT"
[[ -x "$BUNDLE/kotv-engine" ]] || { echo "missing $BUNDLE/kotv-engine" >&2; exit 1; }
kotv_flutter_strip_placeholder_assets "$BUNDLE/data/flutter_assets"
kotv_flutter_asset_engines_reject "$BUNDLE"

mkdir -p "$ROOT/dist"
rm -f "$OUT_ZIP"
(cd "$BUNDLE" && zip -r -q "$OUT_ZIP" .)
ls -lh "$OUT_ZIP"
