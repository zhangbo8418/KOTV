#!/usr/bin/env bash
# 生成 Windows 资源 syso（嵌入 KOTV.ico 到 exe）
# 需要 MinGW windres。在 windows-x64 / windows-arm64 打包前调用。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLAT="${1:-windows-x64}"
ICO="$ROOT/resources/icons/KOTV.ico"

[[ -f "$ICO" ]] || { echo "missing $ICO" >&2; exit 1; }

if ! command -v windres >/dev/null 2>&1; then
  echo "WARNING: windres not found; skip embedding Windows icon" >&2
  exit 0
fi

# MinGW windres 是原生 Win32 程序，读不懂 Git Bash 的 /d/... 路径。
# 把图标与 .rc 放到短 ASCII 临时目录，用相对路径引用最稳。
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/kotv-syso.XXXXXX")"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT
cp -f "$ICO" "$WORKDIR/kotv.ico"
printf 'IDI_ICON1 ICON "kotv.ico"\n' > "$WORKDIR/kotv.rc"

case "$PLAT" in
  windows-x64)
    OUT="$ROOT/rsrc_windows_amd64.syso"
    (cd "$WORKDIR" && windres -i kotv.rc -o kotv.syso -O coff)
    cp -f "$WORKDIR/kotv.syso" "$OUT"
    ;;
  windows-arm64)
    OUT="$ROOT/rsrc_windows_arm64.syso"
    if ! (cd "$WORKDIR" && windres -i kotv.rc -o kotv.syso -O coff); then
      echo "WARNING: windres arm64 failed, skip icon embed" >&2
      exit 0
    fi
    cp -f "$WORKDIR/kotv.syso" "$OUT"
    ;;
  *)
    echo "skip syso for $PLAT"
    exit 0
    ;;
esac

ls -lh "$OUT"
echo "generated $OUT"
