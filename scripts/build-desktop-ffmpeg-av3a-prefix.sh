#!/usr/bin/env bash
# 桌面 FFmpeg 前缀：FongMi FFmpeg 9 + dependency/avs3a（libarcdav3a / AV3A，对齐 TV/webhtv）。
# 支持 Linux / macOS / Windows(GitHub Actions MinGW)。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${KOTV_MPV_BUILD_DIR:-$ROOT/.build/desktop-mpv}"
PREFIX="${KOTV_DESKTOP_FFMPEG_PREFIX:-$BUILD_DIR/prefix}"
FFMPEG_REPO="${KOTV_FFMPEG_REPO:-https://github.com/FongMi/FFmpeg.git}"
FFMPEG_COMMIT="${KOTV_FFMPEG_COMMIT:-04482c8d13ac27b2a9fe93f5d388929eef8af5f4}"
JOBS="${KOTV_MPV_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "${NUMBER_OF_PROCESSORS:-4}")}"

kotv_is_windows_build() {
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
  esac
  [[ "${OS:-}" == "Windows_NT" ]]
}

if kotv_is_windows_build; then
  # GitHub Actions：niXman MinGW（与 Go CGO 相同）
  if [[ -d "/c/mingw-msvcrt/mingw64/bin" ]]; then
    export PATH="/c/mingw-msvcrt/mingw64/bin:$PATH"
  fi
  export PATH="/c/Program Files/NASM:/c/ProgramData/chocolatey/bin:$PATH"
  MAKE="${KOTV_MAKE:-mingw32-make}"
  CMAKE_GENERATOR="${KOTV_CMAKE_GENERATOR:-MinGW Makefiles}"
else
  MAKE="${KOTV_MAKE:-make}"
  CMAKE_GENERATOR="${KOTV_CMAKE_GENERATOR:-Unix Makefiles}"
fi

need() { command -v "$1" >/dev/null || { echo "need $1" >&2; exit 1; }; }
need git
need cmake
need pkg-config
command -v "$MAKE" >/dev/null || need make

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
  [[ -f "$PREFIX/lib/libavcodec.a" ]] \
    || [[ -f "$PREFIX/lib/libavcodec.dll.a" ]] \
    || [[ -f "$PREFIX/lib/libavcodec.dylib" ]] \
    || [[ -f "$PREFIX/lib/libavcodec.so" ]]
}

av3a_in_prefix() {
  local lib="$PREFIX/lib/libavcodec.a"
  [[ -f "$lib" ]] || lib="$PREFIX/lib/libavcodec.dll.a"
  [[ -f "$lib" ]] || return 1
  grep -aqE 'libarcdav3a|AV3A Audio Vivid' "$lib" 2>/dev/null
}

if marker_ok && av3a_in_prefix; then
  echo "ok cached FFmpeg+AV3A prefix: $PREFIX"
  exit 0
fi

echo "==> build desktop FFmpeg+AV3A prefix → $PREFIX ($(uname -s))"
clone_ffmpeg

[[ -f ffmpeg/dependency/avs3a/CMakeLists.txt ]] \
  || { echo "ERROR: missing ffmpeg/dependency/avs3a (wrong FongMi/FFmpeg commit?)" >&2; exit 1; }
grep -q -- '--enable-libarcdav3a' ffmpeg/configure \
  || { echo "ERROR: FongMi FFmpeg lacks --enable-libarcdav3a" >&2; exit 1; }

echo "==> cmake arcdav3a (libarcdav3a) generator=$CMAKE_GENERATOR"
rm -rf arcdav3a-build
cmake -G "$CMAKE_GENERATOR" -S ffmpeg/dependency/avs3a -B arcdav3a-build \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF
cmake --build arcdav3a-build -j"$JOBS"
cmake --install arcdav3a-build

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

echo "==> configure FongMi FFmpeg (static PIC + libarcdav3a)"
cd ffmpeg
$MAKE distclean 2>/dev/null || true

FFMPEG_EXTRA=()
if kotv_is_windows_build; then
  FFMPEG_EXTRA+=(--target-os=mingw64 --arch=x86_64)
fi

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
  ${FFMPEG_EXTRA+"${FFMPEG_EXTRA[@]}"} \
  ${KOTV_FFMPEG_CONFIGURE_EXTRA:-}

$MAKE -j"$JOBS"
$MAKE install

lib="$PREFIX/lib/libavcodec.a"
[[ -f "$lib" ]] || lib="$PREFIX/lib/libavcodec.dll.a"
if ! grep -aqE 'libarcdav3a|AV3A Audio Vivid' "$lib" 2>/dev/null; then
  echo "ERROR: $lib built without AV3A/libarcdav3a" >&2
  exit 1
fi
echo "ok FFmpeg+AV3A prefix: $PREFIX"
