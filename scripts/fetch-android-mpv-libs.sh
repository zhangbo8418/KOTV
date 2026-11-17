#!/usr/bin/env bash
# 兼容入口：不再拉取 fish2018/webhtv 预编译拆库。
# 安卓 MPV 套件改为 FongMi/mpv-android 源码构建（libffmpeg.so + libmpv + libplayer）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
echo "==> fetch-android-mpv-libs: redirect → build-android-mpv-from-source.sh (FongMi)"
exec "$ROOT/scripts/build-android-mpv-from-source.sh"
