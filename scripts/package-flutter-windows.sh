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
ENGINE_OUT="$ROOT/flutter/assets/engine/kotv-engine.exe"
RELEASE_DIR="$ROOT/flutter/build/windows/x64/runner/Release"

echo "==> Flutter Windows package version=$VERSION arch=$ARCH suffix=${SUFFIX:-<none>}"

echo "==> prepare runtime"
chmod +x "$ROOT/bridge/build.sh" "$ROOT"/scripts/*.sh
"$ROOT/scripts/prepare-runtime.sh" windows-x64
"$ROOT/scripts/verify-runtime.sh" runtime windows-x64

echo "==> build Go engine"
(cd "$ROOT/internal/spider" && go run gen_qjsinc.go)
EXTLD="-static-libgcc -static-libstdc++ -Wl,-Bstatic -l:libwinpthread.a -Wl,-Bdynamic"
if [[ "${KOTV_WIN7:-}" == "1" ]]; then
  EXTLD="${EXTLD} -Wl,--subsystem,windows:6.01"
fi
(cd "$ROOT" && go build -ldflags "-s -w -extldflags '${EXTLD}'" -o "$ENGINE_OUT" ./cmd/engine)
if [[ "${KOTV_WIN7:-}" == "1" ]] && command -v pwsh >/dev/null 2>&1; then
  pwsh -File "$ROOT/scripts/check-win7-deps.ps1" -Exe "$ENGINE_OUT"
fi

echo "==> flutter build windows --release"
cd "$ROOT/flutter"
flutter config --enable-windows-desktop
flutter pub get
flutter build windows --release

[[ -f "$RELEASE_DIR/kotv.exe" ]] || { echo "missing $RELEASE_DIR/kotv.exe" >&2; exit 1; }
cp -f "$ENGINE_OUT" "$RELEASE_DIR/kotv-engine.exe"
[[ -d "$RELEASE_DIR/runtime" ]] || { echo "missing $RELEASE_DIR/runtime (CMake install)" >&2; exit 1; }
[[ ! -d "$RELEASE_DIR/runtime/runtime" ]] || { echo "nested runtime/runtime" >&2; exit 1; }

if [[ -f "$ROOT/cmd/updater/updater.exe" ]]; then
  cp -f "$ROOT/cmd/updater/updater.exe" "$RELEASE_DIR/updater.exe"
fi
"$ROOT/scripts/verify-runtime.sh" "$RELEASE_DIR/runtime" windows-x64

echo "==> zip $OUT_ZIP"
rm -f "$OUT_ZIP"

# Git Bash 下绝对路径传给 PowerShell 会被错误改写成 D:\d\a\...；优先用 Git 自带 zip，
# 否则用 cygpath/手动把 /d/... 转成 D:\... 再 Compress-Archive。
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
    # /d/a/foo → D:\a\foo（避免 Git Bash 把路径喂给 PowerShell 变成 D:\d\a\...）
    src_w="$(python3 -c "import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve())" "$src")"
    dest_w="$(python3 -c "import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve())" "$dest")"
  fi
  pwsh -NoProfile -Command "Compress-Archive -Path (Join-Path -Path '$src_w' -ChildPath '*') -DestinationPath '$dest_w' -Force"
}
zip_win "$RELEASE_DIR" "$OUT_ZIP"
ls -lh "$OUT_ZIP"
echo "RELEASE_DIR=$RELEASE_DIR"
