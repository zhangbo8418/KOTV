#!/usr/bin/env bash
# 构建 Win7 专用 WPF 播控遮罩 kotv_win7_chrome.exe（与 Win8+ DComp 线无关）。
# 需要：Windows + .NET SDK 或 VS MSBuild + .NET Framework 4.8 目标包。
# 运行时：目标机需已装 .NET Framework 4.8（Win7 SP1 可装）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJ_DIR="$ROOT/flutter/windows/win7_chrome"
PROJ="$PROJ_DIR/KotvWin7Chrome.csproj"
OUT_DIR="${1:-$PROJ_DIR/bin/Release}"

if [[ ! -f "$PROJ" ]]; then
  echo "missing $PROJ" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

build_with_dotnet() {
  command -v dotnet >/dev/null 2>&1 || return 1
  echo "==> dotnet restore + build Win7 WPF chrome → $OUT_DIR"
  (cd "$PROJ_DIR" && dotnet restore "$PROJ" -v m)
  (cd "$PROJ_DIR" && dotnet build "$PROJ" -c Release -p:OutputPath="$OUT_DIR/" --no-restore -v m)
}

build_with_msbuild() {
  local msbuild=""
  if command -v msbuild >/dev/null 2>&1; then
    msbuild="$(command -v msbuild)"
  else
    local vswhere="/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
    if [[ -x "$vswhere" ]]; then
      msbuild="$("$vswhere" -latest -requires Microsoft.Component.MSBuild -find 'MSBuild/**/Bin/MSBuild.exe' | head -n1)"
    fi
  fi
  [[ -n "$msbuild" && -f "$msbuild" ]] || return 1
  echo "==> MSBuild restore + build Win7 WPF chrome → $OUT_DIR"
  "$msbuild" "$PROJ" -t:Restore -p:Configuration=Release -v:m
  "$msbuild" "$PROJ" -t:Build -p:Configuration=Release -p:OutputPath="$OUT_DIR/" -v:m
}

if ! build_with_dotnet; then
  if ! build_with_msbuild; then
    echo "dotnet/MSBuild not found; need .NET SDK or VS Build Tools + net48 targeting pack" >&2
    exit 1
  fi
fi

[[ -f "$OUT_DIR/kotv_win7_chrome.exe" ]] || {
  echo "missing $OUT_DIR/kotv_win7_chrome.exe" >&2
  ls -la "$OUT_DIR" >&2 || true
  exit 1
}
echo "ok $OUT_DIR/kotv_win7_chrome.exe"
