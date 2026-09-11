#!/usr/bin/env bash
# 桌面 MPV 的 ISO：DVD（libdvdread+libdvdnav）和蓝光（libbluray，内置 UDF 读 .iso）。
# 静态装进 PREFIX，避免 Homebrew / 系统库串架构。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${KOTV_MPV_BUILD_DIR:-$ROOT/.build/desktop-mpv}"
PREFIX="${KOTV_DESKTOP_FFMPEG_PREFIX:-$BUILD_DIR/prefix}"
STAMP="$PREFIX/.kotv-iso-libs-v1"
JOBS="${KOTV_MPV_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "${NUMBER_OF_PROCESSORS:-4}")}"

DVDREAD_VER=7.0.1
DVDREAD_SHA=2e3e04a305c15c3963aa03ae1b9a83c1d239880003fcf3dde986d3943355d407
DVDNAV_VER=7.0.0
DVDNAV_SHA=a2a18f5ad36d133c74bf9106b6445806fa253b09141a46392550394b647b221e
BLURAY_VER=1.4.1
BLURAY_SHA=76b5dc40097f28dca4ebb009c98ed51321b2927453f75cc72cf74acd09b9f449

need() { command -v "$1" >/dev/null || { echo "need $1" >&2; exit 1; }; }
need curl
need tar
need make
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

if [[ -f "$STAMP" && -f "$PREFIX/lib/pkgconfig/libbluray.pc" && -f "$PREFIX/lib/pkgconfig/dvdnav.pc" ]]; then
  echo "ok cached ISO libs (libbluray $BLURAY_VER, dvdnav $DVDNAV_VER)"
  exit 0
fi

mkdir -p "$PREFIX" "$BUILD_DIR/src"
src="$BUILD_DIR/src"

cflags=""
if [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
  arch="${KOTV_MPV_MACOS_ARCH:-$(uname -m)}"
  cflags="-arch $arch"
  export CFLAGS="${CFLAGS:-} $cflags"
  export CXXFLAGS="${CXXFLAGS:-} $cflags"
  export LDFLAGS="${LDFLAGS:-} $cflags"
fi

build_autotools() {
  local name="$1" tar="$2"
  rm -rf "$BUILD_DIR/$name"
  mkdir -p "$BUILD_DIR/$name"
  tar -xf "$tar" -C "$BUILD_DIR/$name" --strip-components=1
  (
    cd "$BUILD_DIR/$name"
    ./configure --prefix="$PREFIX" --disable-shared --enable-static --disable-apidoc
    make -j"$JOBS"
    make install
  )
}

echo "==> ISO libs → $PREFIX"
fetch "https://downloads.videolan.org/pub/videolan/libdvdread/${DVDREAD_VER}/libdvdread-${DVDREAD_VER}.tar.xz" \
  "$src/libdvdread-${DVDREAD_VER}.tar.xz" "$DVDREAD_SHA"
fetch "https://downloads.videolan.org/pub/videolan/libdvdnav/${DVDNAV_VER}/libdvdnav-${DVDNAV_VER}.tar.xz" \
  "$src/libdvdnav-${DVDNAV_VER}.tar.xz" "$DVDNAV_SHA"
fetch "https://downloads.videolan.org/pub/videolan/libbluray/${BLURAY_VER}/libbluray-${BLURAY_VER}.tar.xz" \
  "$src/libbluray-${BLURAY_VER}.tar.xz" "$BLURAY_SHA"

build_autotools dvdread "$src/libdvdread-${DVDREAD_VER}.tar.xz"
build_autotools dvdnav "$src/libdvdnav-${DVDNAV_VER}.tar.xz"

need meson
need ninja
rm -rf "$BUILD_DIR/libbluray"
mkdir -p "$BUILD_DIR/libbluray"
tar -xf "$src/libbluray-${BLURAY_VER}.tar.xz" -C "$BUILD_DIR/libbluray" --strip-components=1
meson setup "$BUILD_DIR/libbluray-build" "$BUILD_DIR/libbluray" \
  --prefix="$PREFIX" \
  --libdir=lib \
  --buildtype=release \
  -Ddefault_library=static \
  -Denable_tools=false \
  -Dbdj_jar=disabled \
  -Dfontconfig=disabled \
  -Dfreetype=disabled \
  -Dlibxml2=disabled
meson compile -C "$BUILD_DIR/libbluray-build" -j "$JOBS"
meson install -C "$BUILD_DIR/libbluray-build"

pkg-config --exists dvdread
pkg-config --exists dvdnav
pkg-config --exists libbluray
echo "iso-libs ${DVDREAD_VER}/${DVDNAV_VER}/${BLURAY_VER}" >"$STAMP"
echo "ok ISO libs: dvdread $(pkg-config --modversion dvdread) dvdnav $(pkg-config --modversion dvdnav) libbluray $(pkg-config --modversion libbluray)"
