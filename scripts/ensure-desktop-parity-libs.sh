#!/usr/bin/env bash
# 安卓 MPV 里、桌面也能用的功能：iconv、uchardet、libarchive、rubberband。
# 静态装进 PREFIX。android/aaudio/mediacodec 和 libavdevice 不在这里。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${KOTV_MPV_BUILD_DIR:-$ROOT/.build/desktop-mpv}"
PREFIX="${KOTV_DESKTOP_FFMPEG_PREFIX:-$BUILD_DIR/prefix}"
STAMP="$PREFIX/.kotv-parity-libs-v1"
JOBS="${KOTV_MPV_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "${NUMBER_OF_PROCESSORS:-4}")}"

ICONV_VER=1.19
ICONV_SHA=88dd96a8c0464eca144fc791ae60cd31cd8ee78321e67397e25fc095c4a19aa6
UCHARDET_VER=0.0.8
UCHARDET_SHA=5aa402a1b5b1dbb8d81096f141ff1224e079f4d3a1db0f79ecca782756d3a416
ARCHIVE_VER=3.8.7
ARCHIVE_SHA=d3a8ba457ae25c27c84fd2830a2efdcc5b1d40bf585d4eb0d35f47e99e5d4774
ZLIB_VER=1.3.1
ZLIB_SHA=9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23
RUBBER_VER=4.0.0
RUBBER_SHA=24300f48a8014b7c863b573a9647e61b1b19b37875e2cdd92005e64c6424d266

need() { command -v "$1" >/dev/null || { echo "need $1" >&2; exit 1; }; }
need curl
need tar
need make
need cmake
need pkg-config

is_windows() {
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
  esac
  [[ "${OS:-}" == "Windows_NT" ]]
}

fetch() {
  local url="$1" dest="$2" sha="$3"
  if [[ -f "$dest" ]]; then
    return
  fi
  mkdir -p "$(dirname "$dest")"
  curl -fL --retry 5 --retry-delay 2 -o "$dest.partial" "$url"
  mv "$dest.partial" "$dest"
  if command -v shasum >/dev/null; then
    echo "$sha  $dest" | shasum -a 256 -c -
  elif command -v sha256sum >/dev/null; then
    echo "$sha  $dest" | sha256sum -c -
  fi
}

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
if is_windows || [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
  export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
fi

if [[ -f "$STAMP" && -f "$PREFIX/lib/pkgconfig/uchardet.pc" && -f "$PREFIX/lib/pkgconfig/libarchive.pc" && -f "$PREFIX/lib/pkgconfig/rubberband.pc" ]]; then
  echo "ok cached parity libs (uchardet/libarchive/rubberband)"
  exit 0
fi

cflags=""
if [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
  arch="${KOTV_MPV_MACOS_ARCH:-$(uname -m)}"
  cflags="-arch $arch"
fi
export CFLAGS="${CFLAGS:-} $cflags"
export CXXFLAGS="${CXXFLAGS:-} $cflags"
export LDFLAGS="${LDFLAGS:-} $cflags"

src="$BUILD_DIR/src"
mkdir -p "$src" "$PREFIX"

cmake_gen=(Ninja)
command -v ninja >/dev/null || cmake_gen=(Unix Makefiles)
if is_windows; then
  cmake_gen=(MinGW Makefiles)
fi

echo "==> parity libs → $PREFIX"
if is_windows || [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
  fetch "https://ftp.gnu.org/pub/gnu/libiconv/libiconv-${ICONV_VER}.tar.gz" \
    "$src/libiconv-${ICONV_VER}.tar.gz" "$ICONV_SHA"
  rm -rf "$BUILD_DIR/libiconv"
  mkdir -p "$BUILD_DIR/libiconv"
  tar -xf "$src/libiconv-${ICONV_VER}.tar.gz" -C "$BUILD_DIR/libiconv" --strip-components=1
  (
    cd "$BUILD_DIR/libiconv"
    ./configure --prefix="$PREFIX" --disable-shared --enable-static --disable-nls
    make -j"$JOBS"
    make install
  )
fi

if [[ ! -f "$PREFIX/lib/libz.a" && ! -f "$PREFIX/lib/libzlibstatic.a" ]]; then
  fetch "https://zlib.net/zlib-${ZLIB_VER}.tar.gz" "$src/zlib-${ZLIB_VER}.tar.gz" "$ZLIB_SHA" \
    || fetch "https://github.com/madler/zlib/releases/download/v${ZLIB_VER}/zlib-${ZLIB_VER}.tar.gz" \
      "$src/zlib-${ZLIB_VER}.tar.gz" "$ZLIB_SHA"
  rm -rf "$BUILD_DIR/zlib"
  mkdir -p "$BUILD_DIR/zlib"
  tar -xf "$src/zlib-${ZLIB_VER}.tar.gz" -C "$BUILD_DIR/zlib" --strip-components=1
  cmake -S "$BUILD_DIR/zlib" -B "$BUILD_DIR/zlib-build" -G "${cmake_gen[0]}" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF
  cmake --build "$BUILD_DIR/zlib-build" -j"$JOBS"
  cmake --install "$BUILD_DIR/zlib-build"
fi

fetch "https://gitlab.freedesktop.org/uchardet/uchardet/-/archive/v${UCHARDET_VER}/uchardet-v${UCHARDET_VER}.tar.gz" \
  "$src/uchardet-${UCHARDET_VER}.tar.gz" "$UCHARDET_SHA"
rm -rf "$BUILD_DIR/uchardet"
mkdir -p "$BUILD_DIR/uchardet"
tar -xf "$src/uchardet-${UCHARDET_VER}.tar.gz" -C "$BUILD_DIR/uchardet" --strip-components=1
cmake -S "$BUILD_DIR/uchardet" -B "$BUILD_DIR/uchardet-build" -G "${cmake_gen[0]}" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_PREFIX_PATH="$PREFIX" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DBUILD_BINARY=OFF
cmake --build "$BUILD_DIR/uchardet-build" -j"$JOBS"
cmake --install "$BUILD_DIR/uchardet-build"

fetch "https://github.com/libarchive/libarchive/releases/download/v${ARCHIVE_VER}/libarchive-${ARCHIVE_VER}.tar.xz" \
  "$src/libarchive-${ARCHIVE_VER}.tar.xz" "$ARCHIVE_SHA"
rm -rf "$BUILD_DIR/libarchive"
mkdir -p "$BUILD_DIR/libarchive"
tar -xf "$src/libarchive-${ARCHIVE_VER}.tar.xz" -C "$BUILD_DIR/libarchive" --strip-components=1
cmake -S "$BUILD_DIR/libarchive" -B "$BUILD_DIR/libarchive-build" -G "${cmake_gen[0]}" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_PREFIX_PATH="$PREFIX" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DENABLE_TEST=OFF \
  -DENABLE_TAR=OFF \
  -DENABLE_CPIO=OFF \
  -DENABLE_CAT=OFF \
  -DENABLE_OPENSSL=OFF \
  -DENABLE_LIBB2=OFF \
  -DENABLE_LZ4=OFF \
  -DENABLE_LZO=OFF \
  -DENABLE_ZSTD=OFF \
  -DENABLE_LZMA=OFF \
  -DENABLE_BZip2=OFF \
  -DENABLE_LIBXML2=OFF \
  -DENABLE_EXPAT=OFF \
  -DENABLE_PCREPOSIX=OFF \
  -DENABLE_ZLIB=ON
cmake --build "$BUILD_DIR/libarchive-build" -j"$JOBS"
cmake --install "$BUILD_DIR/libarchive-build"

need meson
need ninja
fetch "https://github.com/breakfastquay/rubberband/archive/refs/tags/v${RUBBER_VER}.tar.gz" \
  "$src/rubberband-${RUBBER_VER}.tar.gz" "$RUBBER_SHA"
rm -rf "$BUILD_DIR/rubberband"
mkdir -p "$BUILD_DIR/rubberband"
tar -xf "$src/rubberband-${RUBBER_VER}.tar.gz" -C "$BUILD_DIR/rubberband" --strip-components=1
meson setup "$BUILD_DIR/rubberband-build" "$BUILD_DIR/rubberband" \
  --prefix="$PREFIX" \
  --libdir=lib \
  --buildtype=release \
  -Ddefault_library=static \
  -Dfft=builtin \
  -Dresampler=builtin \
  -Djni=disabled \
  -Dladspa=disabled \
  -Dlv2=disabled \
  -Dvamp=disabled \
  -Dcmdline=disabled \
  -Dtests=disabled
meson compile -C "$BUILD_DIR/rubberband-build" -j "$JOBS"
meson install -C "$BUILD_DIR/rubberband-build"

pkg-config --exists uchardet
pkg-config --exists libarchive
pkg-config --exists rubberband
echo "parity uchardet=${UCHARDET_VER} archive=${ARCHIVE_VER} rubberband=${RUBBER_VER}" >"$STAMP"
echo "ok parity libs: uchardet $(pkg-config --modversion uchardet) libarchive $(pkg-config --modversion libarchive) rubberband $(pkg-config --modversion rubberband)"
