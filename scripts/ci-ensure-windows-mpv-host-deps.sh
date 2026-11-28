#!/usr/bin/env bash
# CI Windows：桌面 libmpv 源码构建所需主机工具（nasm / vulkan / meson / ninja / perl）。
# 用法: ./scripts/ci-ensure-windows-mpv-host-deps.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# strawberryperl：runner 常已预装；choco 503 时不挡后续
choco install strawberryperl -y --no-progress || true
chmod +x "$ROOT/scripts/ci-ensure-windows-nasm.sh" "$ROOT/scripts/ci-ensure-windows-vulkan-sdk.sh"
"$ROOT/scripts/ci-ensure-windows-nasm.sh" || true
"$ROOT/scripts/ci-ensure-windows-vulkan-sdk.sh"
python -m pip install meson ninja

export PATH="/c/Strawberry/perl/bin:/c/mingw-msvcrt/mingw64/bin:/c/Program Files/NASM:/c/ProgramData/chocolatey/bin:${PATH:-}"
export PATH="$(python -c 'import sysconfig; print(sysconfig.get_path("scripts"))'):$PATH"

if command -v gcc >/dev/null 2>&1; then gcc --version; fi
nasm -v || true
meson --version
perl -MLocale::Maketext -e 'print qq(ok Locale::Maketext\n)' || true

if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "C:\\Strawberry\\perl\\bin" >>"$GITHUB_PATH"
  echo "C:\\Program Files\\NASM" >>"$GITHUB_PATH"
fi
