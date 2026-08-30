#!/usr/bin/env bash
# 桌面 FFmpeg 前缀：FongMi FFmpeg 9 + dependency/avs3a（libarcdav3a / AV3A，对齐 TV/webhtv）。
# 产物：$PREFIX/{include,lib,lib/pkgconfig} 供 build-desktop-mpv-from-source.sh 链接 libmpv。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${KOTV_MPV_BUILD_DIR:-$ROOT/.build/desktop-mpv}"
PREFIX="${KOTV_DESKTOP_FFMPEG_PREFIX:-$BUILD_DIR/prefix}"
FFMPEG_REPO="${KOTV_FFMPEG_REPO:-https://github.com/FongMi/FFmpeg.git}"
FFMPEG_COMMIT="${KOTV_FFMPEG_COMMIT:-04482c8d13ac27b2a9fe93f5d388929eef8af5f4}"
JOBS="${KOTV_MPV_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

need() { command -v "$1" >/dev/null || { echo "need $1" >&2; exit 1; }; }
need git
need cmake
need make
need pkg-config

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

clone_ffmpeg() {
  if [[ -d ffmpeg/.git ]]; then
    git -C ffmpeg fetch --depth 1 origin "$FFMPEG_COMMIT" 2>/dev/null || true
    git -C ffmpeg checkout -q "$FFMPEG_COMMIT"
    return
  fi
  git clone --filter=blob:none --depth 1 "$FFMPEG_REPO" ffmpeg
  git -C ffmpeg fetch --depth 1 origin "$FFMPEG_COMMIT"
  git -C ffmpeg checkout -q "$FFMPEG_COMMIT"
}

marker_ok() {
  [[ -f "$PREFIX/lib/libavcodec.a" ]] || [[ -f "$PREFIX/lib/libavcodec.dylib" ]] || [[ -f "$PREFIX/lib/libavcodec.so" ]]
}

if marker_ok; then
  if grep -aqE 'libarcdav3a|AV3A Audio Vivid' "$PREFIX/lib/libavcodec.a" 2>/dev/null \
    || grep -aqE 'libarcdav3a|AV3A Audio Vivid' "$PREFIX/lib/libavcodec.so" 2>/dev/null \
    || grep -aqE 'libarcdav3a|AV3A Audio Vivid' "$PREFIX/lib/libavcodec.dylib" 2>/dev/null; then
    echo "ok cached FFmpeg+AV3A prefix: $PREFIX"
    exit 0
  fi
fi

echo "==> build desktop FFmpeg+AV3A prefix → $PREFIX"
clone_ffmpeg

[[ -f ffmpeg/dependency/avs3a/CMakeLists.txt ]] \
  || { echo "ERROR: missing ffmpeg/dependency/avs3a (wrong FongMi/FFmpeg commit?)" >&2; exit 1; }
grep -q -- '--enable-libarcdav3a' ffmpeg/configure \
  || { echo "ERROR: FongMi FFmpeg lacks --enable-libarcdav3a" >&2; exit 1; }

echo "==> cmake arcdav3a (libarcdav3a)"
rm -rf arcdav3a-build
cmake -S ffmpeg/dependency/avs3a -B arcdav3a-build \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF
cmake --build arcdav3a-build -j"$JOBS"
cmake --install arcdav3a-build

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

echo "==> configure FongMi FFmpeg (static PIC + libarcdav3a)"
cd ffmpeg
make distclean 2>/dev/null || true
./configure \
  --prefix="$PREFIX" \
  --enable-static \
  --disable-shared \
  --enable-pic \
  --enable-gpl \
  --enable-version3 \
  --enable-libarcdav3a \
  --disable-programs \
  --disable-doc \
  --disable-debug \
  ${KOTV_FFMPEG_CONFIGURE_EXTRA:-}

make -j"$JOBS"
make install

if ! grep -aqE 'libarcdav3a|AV3A Audio Vivid' "$PREFIX/lib/libavcodec.a" 2>/dev/null; then
  echo "ERROR: libavcodec.a built without AV3A/libarcdav3a" >&2
  exit 1
fi
echo "ok FFmpeg+AV3A prefix: $PREFIX"
