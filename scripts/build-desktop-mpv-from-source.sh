#!/usr/bin/env bash
# CI 兜底：预编译拉取失败时从源码编 libmpv（耗时长，仅 KOTV_BUILD_MPV_FROM_SOURCE=1）。
# Win7 线优先用 fetch-desktop-mpv-libs.sh 的 shinchiro 非-v3 包，通常不必跑本脚本。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLAT="${1:-}"
ASSET="$ROOT/flutter/assets/mpv-libs"
mkdir -p "$ASSET/windows" "$ASSET/linux" "$ASSET/macos"

case "$PLAT" in
  windows|win)
    echo "Windows: use fetch-desktop-mpv-libs.sh (mpv-winbuild-cmake dev 7z)." >&2
    echo "  Source build not wired; set KOTV_MPV_WIN_URL to a pinned mpv-dev-x86_64.7z." >&2
    exit 1
    ;;
  linux)
    need() { command -v "$1" >/dev/null || { echo "need $1" >&2; exit 1; }; }
    need meson
    need ninja
    need git
    need curl
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    git clone --depth 1 --branch v0.37.0 https://github.com/mpv-player/mpv.git "$work/mpv"
    cd "$work/mpv"
    meson setup build -Ddefault_library=shared -Dlibmpv=true -Dcplayer=false -Dmanpage-build=disabled
    ninja -C build
    cp -f build/libmpv.so.2 "$ASSET/linux/libmpv.so.2"
    echo "built linux/libmpv.so.2"
    ;;
  macos|darwin)
    need() { command -v "$1" >/dev/null || { echo "need $1" >&2; exit 1; }; }
    need meson
    need ninja
    need git
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    git clone --depth 1 --branch v0.37.0 https://github.com/mpv-player/mpv.git "$work/mpv"
    cd "$work/mpv"
    meson setup build -Ddefault_library=shared -Dlibmpv=true -Dcplayer=false -Dmanpage-build=disabled
    ninja -C build
    cp -f build/libmpv.dylib "$ASSET/macos/libmpv.dylib"
    echo "built macOS/libmpv.dylib"
    ;;
  *)
    echo "usage: $0 {windows|linux|macos}" >&2
    exit 1
    ;;
esac
