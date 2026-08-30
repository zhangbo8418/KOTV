#!/usr/bin/env bash
# 已废弃：页内 libmpv 不进 runtime，与 fvp/mdk 同目录。
# 请用：bundle-app-libmpv.sh <KO影视.app | install-dir>
set -euo pipefail
echo "install-runtime-libmpv.sh is obsolete — libmpv is not part of runtime." >&2
echo "use: $(cd "$(dirname "$0")" && pwd)/bundle-app-libmpv.sh <app-dir>" >&2
if [[ -n "${1:-}" && -d "$1/libmpv" ]]; then
  rm -rf "$1/libmpv"
  echo "removed $1/libmpv"
fi
exit 0
