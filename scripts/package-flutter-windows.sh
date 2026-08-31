#!/usr/bin/env bash
# 打包 Flutter Windows：runtime + Go 引擎 + UI
# 环境变量：
#   KOTV_VERSION          发行版本（可带 v）
#   KOTV_WIN7=1           Win7 线（子系统 6.01 + check-win7-deps）
#   KOTV_OUT_SUFFIX       文件名后缀，如 -win7 → KO影视-ver-x86_64-win7.zip
# 产物（仓库根目录）：
#   KO影视-{ver}-x86_64{suffix}.zip
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=kotv-release-name.sh
source "$ROOT/scripts/kotv-release-name.sh"

VERSION="$(kotv_release_version "$ROOT/flutter/pubspec.yaml")"
ARCH="$(kotv_release_arch windows-x64)"
SUFFIX="${KOTV_OUT_SUFFIX:-}"
OUT_ZIP="${ROOT}/KO影视-${VERSION}-${ARCH}${SUFFIX}.zip"
ENGINE_DIR="$ROOT/dist/_win_engine"
ENGINE_OUT="$ENGINE_DIR/kotv-engine.exe"
RELEASE_DIR="$ROOT/flutter/build/windows/x64/runner/Release"
ASSETS_ENG="$ROOT/flutter/assets/engine"

echo "==> Flutter Windows package version=$VERSION arch=$ARCH suffix=${SUFFIX:-<none>}"

chmod +x "$ROOT/bridge/build.sh" "$ROOT"/scripts/*.sh

# Win7 线 / Flutter 3.19（Dart 3.3）：必须先 adapt，否则 video_player_android 2.11 要 SDK ^3.10
if [[ "${KOTV_WIN7:-}" == "1" ]] || flutter --version 2>&1 | grep -qE 'Dart 3\.3\.|Flutter 3\.19'; then
  echo "==> adapt pubspec for Win7 / Dart 3.3"
  "$ROOT/scripts/adapt-flutter-win7-sdk.sh"
fi
if [[ "${KOTV_WIN7:-}" == "1" ]]; then
  echo "==> fetch embedded fonts (Win7 only)"
  "$ROOT/scripts/fetch-flutter-fonts.sh"
fi

if [[ "${KOTV_WIN7:-}" == "1" ]]; then
  export KOTV_MPV_WIN7=1
fi
echo "==> fetch desktop libmpv (AV3A source)"
"$ROOT/scripts/fetch-desktop-mpv-libs.sh"
echo "==> prepare runtime"
"$ROOT/scripts/prepare-runtime.sh" windows-x64
"$ROOT/scripts/verify-runtime.sh" runtime windows-x64

echo "==> build Go engine"
(cd "$ROOT/internal/spider" && go run gen_qjsinc.go)
EXTLD="-static-libgcc -static-libstdc++ -Wl,-Bstatic -l:libwinpthread.a -Wl,-Bdynamic"
if [[ "${KOTV_WIN7:-}" == "1" ]]; then
  EXTLD="${EXTLD} -Wl,--subsystem,windows:6.01"
fi
mkdir -p "$ENGINE_DIR"
# 相对路径输出，避免 Git Bash 绝对路径让 go/Windows 写丢
(cd "$ROOT" && go build -ldflags "-s -w -extldflags '${EXTLD}'" \
  -o "dist/_win_engine/kotv-engine.exe" ./cmd/engine)
[[ -f "$ENGINE_OUT" ]] || { echo "missing engine: $ENGINE_OUT" >&2; ls -la "$ENGINE_DIR" >&2; exit 1; }
if [[ "${KOTV_WIN7:-}" == "1" ]] && command -v pwsh >/dev/null 2>&1; then
  pwsh -File "$ROOT/scripts/check-win7-deps.ps1" -Exe "$ENGINE_OUT"
fi

# Git Bash 下 `rm kotv-engine` 可能误删 kotv-engine.exe；用 PowerShell -LiteralPath。
# 打包前清空 assets 里的引擎，避免错误架构二进制进 flutter_assets；安装旁路拷贝到 Release。
echo "==> clear assets/engine binaries (LiteralPath)"
pwsh -NoProfile -Command "
  \$dir = '${ASSETS_ENG}' -replace '/', '\'
  foreach (\$n in @('kotv-engine', 'kotv-engine.exe')) {
    \$p = Join-Path \$dir \$n
    if (Test-Path -LiteralPath \$p) { Remove-Item -LiteralPath \$p -Force; Write-Host \"removed \$p\" }
  }
"

echo "==> flutter build windows --release"
cd "$ROOT/flutter"
# shellcheck source=kotv-fvp-deps.sh
source "$ROOT/scripts/kotv-fvp-deps.sh"
kotv_export_fvp_deps
flutter config --enable-windows-desktop
"$ROOT/scripts/flutter-pub-get.sh"
kotv_ensure_mdk_windows_sdk
flutter build windows --release

[[ -f "$RELEASE_DIR/kotv.exe" ]] || { echo "missing $RELEASE_DIR/kotv.exe" >&2; exit 1; }
cp -f "$ENGINE_OUT" "$RELEASE_DIR/kotv-engine.exe"
# 清掉可能误进 assets 的无后缀文件（LiteralPath）
pwsh -NoProfile -Command "
  \$paths = @(
    '${RELEASE_DIR}/kotv-engine',
    '${RELEASE_DIR}/data/flutter_assets/assets/engine/kotv-engine'
  )
  foreach (\$raw in \$paths) {
    \$p = \$raw -replace '/', '\'
    if (Test-Path -LiteralPath \$p) { Remove-Item -LiteralPath \$p -Force }
  }
"
[[ -f "$RELEASE_DIR/kotv-engine.exe" ]] || { echo "missing Release kotv-engine.exe" >&2; exit 1; }
[[ -d "$RELEASE_DIR/runtime" ]] || { echo "missing $RELEASE_DIR/runtime (CMake install)" >&2; exit 1; }
[[ ! -d "$RELEASE_DIR/runtime/runtime" ]] || { echo "nested runtime/runtime" >&2; exit 1; }

if [[ -f "$ROOT/cmd/updater/updater.exe" ]]; then
  cp -f "$ROOT/cmd/updater/updater.exe" "$RELEASE_DIR/updater.exe"
fi
"$ROOT/scripts/verify-runtime.sh" "$RELEASE_DIR/runtime" windows-x64

chmod +x "$ROOT/scripts/bundle-app-libmpv.sh"
"$ROOT/scripts/bundle-app-libmpv.sh" "$RELEASE_DIR"
[[ -f "$RELEASE_DIR/mpv-2.dll" || -f "$RELEASE_DIR/libmpv-2.dll" ]] || {
  echo "missing mpv-2.dll next to kotv.exe" >&2
  exit 1
}
asset_n="$(find "$ROOT/flutter/assets/mpv-libs/windows" -maxdepth 1 -type f -iname '*.dll' 2>/dev/null | wc -l | tr -d ' ')"
if [[ "${asset_n:-0}" -lt 2 ]]; then
  echo "ERROR: flutter/assets/mpv-libs/windows 只有 ${asset_n:-0} 个 DLL" >&2
  ls -la "$ROOT/flutter/assets/mpv-libs/windows" >&2 || true
  exit 1
fi
chmod +x "$ROOT/scripts/verify-windows-mpv-bundle.sh"
"$ROOT/scripts/verify-windows-mpv-bundle.sh" "$RELEASE_DIR"
if [[ "${KOTV_WIN7:-}" != "1" && ! -f "$RELEASE_DIR/vulkan-1.dll" ]]; then
  echo "ERROR: vulkan-1.dll missing next to kotv.exe (required for Win10+ libplacebo Vulkan)" >&2
  exit 1
fi
if [[ "${KOTV_WIN7:-}" == "1" && -f "$RELEASE_DIR/vulkan-1.dll" ]]; then
  echo "WARN: Win7 package ships vulkan-1.dll (expected D3D11-only build)" >&2
fi
echo "ok mpv-2.dll + $asset_n sibling dlls staged from assets"

echo "==> zip $OUT_ZIP"
rm -f "$OUT_ZIP"

zip_win() {
  local src="$1" dest="$2"
  local zip_bin=""
  for c in zip /usr/bin/zip "/c/Program Files/Git/usr/bin/zip.exe" "/mingw64/bin/zip"; do
    if command -v "$c" >/dev/null 2>&1; then zip_bin="$(command -v "$c")"; break; fi
    if [[ -x "$c" ]]; then zip_bin="$c"; break; fi
  done
  if [[ -n "$zip_bin" ]]; then
    (cd "$src" && "$zip_bin" -r -q "$dest" .)
    return
  fi
  local src_w dest_w
  if command -v cygpath >/dev/null 2>&1; then
    src_w="$(cygpath -w "$src")"
    dest_w="$(cygpath -w "$dest")"
  else
    src_w="$(python3 -c "import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve())" "$src")"
    dest_w="$(python3 -c "import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve())" "$dest")"
  fi
  pwsh -NoProfile -Command "Compress-Archive -Path (Join-Path -Path '$src_w' -ChildPath '*') -DestinationPath '$dest_w' -Force"
}
zip_win "$RELEASE_DIR" "$OUT_ZIP"
ls -lh "$OUT_ZIP"
echo "RELEASE_DIR=$RELEASE_DIR"
