#!/usr/bin/env bash
# 把 libnghttp3 + libngtcp2（OpenSSL crypto）装进 PREFIX，供 curl HTTP/3。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=kotv-win-build-env.sh
source "$ROOT/scripts/kotv-win-build-env.sh"
BUILD_DIR="${KOTV_MPV_BUILD_DIR:-$ROOT/.build/desktop-mpv}"
PREFIX="${KOTV_DESKTOP_FFMPEG_PREFIX:-$BUILD_DIR/prefix}"
JOBS="${KOTV_MPV_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "${NUMBER_OF_PROCESSORS:-4}")}"
NGHTTP3_VER="${KOTV_NGHTTP3_VER:-1.11.0}"
NGTCP2_VER="${KOTV_NGTCP2_VER:-1.14.0}"
WIN7_CFLAGS="$(kotv_win7_cflags)"

kotv_native_path() {
  local p="$1"
  if kotv_is_windows_build && command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$p"
  else
    printf '%s' "$p"
  fi
}

mkdir -p "$PREFIX/lib/pkgconfig" "$PREFIX/include" "$PREFIX/lib" "$BUILD_DIR"
export PKG_CONFIG_PATH="$(kotv_native_path "$PREFIX/lib/pkgconfig")${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

chmod +x "$ROOT/scripts/ensure-desktop-openssl.sh"
"$ROOT/scripts/ensure-desktop-openssl.sh"
export PKG_CONFIG_PATH="$(kotv_native_path "$PREFIX/lib/pkgconfig")${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

if pkg-config --exists libnghttp3 libngtcp2 2>/dev/null \
  && (pkg-config --exists libngtcp2_crypto_ossl 2>/dev/null || pkg-config --exists libngtcp2_crypto_quictls 2>/dev/null) \
  && { [[ -f "$PREFIX/lib/libnghttp3.a" || -f "$PREFIX/lib/libnghttp3.dll.a" || -f "$PREFIX/lib/libnghttp3.dylib" || -f "$PREFIX/lib/libnghttp3.so" \
      || -f "$PREFIX/bin/libnghttp3.dll" ]]; }; then
  echo "ok cached nghttp3=$(pkg-config --modversion libnghttp3) ngtcp2=$(pkg-config --modversion libngtcp2)"
  exit 0
fi

need() { command -v "$1" >/dev/null || { echo "need $1" >&2; exit 1; }; }
need cmake
need curl
need tar
kotv_clean_win_path "$BUILD_DIR/bin"

pref="$(kotv_native_path "$PREFIX")"
gen=Ninja
command -v ninja >/dev/null 2>&1 || gen="Unix Makefiles"
if kotv_is_windows_build; then
  gen="MinGW Makefiles"
fi

fetch_extract() {
  local name="$1" ver="$2" repo="$3"
  local src="$BUILD_DIR/$name-$ver"
  local tarball="$BUILD_DIR/$name-$ver.tar.gz"
  if [[ -f "$src/CMakeLists.txt" ]]; then
    return 0
  fi
  curl -fsSL -o "$tarball" "https://github.com/${repo}/archive/refs/tags/v${ver}.tar.gz"
  rm -rf "$src" "$BUILD_DIR/$name-$ver-tmp"
  mkdir -p "$BUILD_DIR/$name-$ver-tmp"
  tar -xzf "$tarball" -C "$BUILD_DIR/$name-$ver-tmp"
  local found
  found="$(find "$BUILD_DIR/$name-$ver-tmp" -maxdepth 1 -type d -name "${name}-*" | head -1 || true)"
  [[ -n "$found" ]] || { echo "ERROR: extract $name failed" >&2; exit 1; }
  mv "$found" "$src"
  rm -rf "$BUILD_DIR/$name-$ver-tmp"
}

build_cmake_lib() {
  local name="$1"
  local src="$2"
  local build="$BUILD_DIR/$name-build"
  shift 2
  rm -rf "$build"
  mkdir -p "$build"
  echo "==> build $name → $pref"
  local -a winflags=()
  if kotv_is_windows_build; then
    winflags+=(-DCMAKE_C_FLAGS="${WIN7_CFLAGS}" -DCMAKE_CXX_FLAGS="${WIN7_CFLAGS}")
  fi
  cmake -S "$src" -B "$build" -G "$gen" \
    -DCMAKE_INSTALL_PREFIX="$pref" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DCMAKE_PREFIX_PATH="$pref" \
    "${winflags[@]}" \
    "$@"
  cmake --build "$build" -j"$JOBS"
  cmake --install "$build"
}

fetch_extract nghttp3 "$NGHTTP3_VER" ngtcp2/nghttp3
build_cmake_lib nghttp3 "$BUILD_DIR/nghttp3-$NGHTTP3_VER" \
  -DENABLE_LIB_ONLY=ON -DBUILD_TESTING=OFF

export PKG_CONFIG_PATH="$(kotv_native_path "$PREFIX/lib/pkgconfig")${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

fetch_extract ngtcp2 "$NGTCP2_VER" ngtcp2/ngtcp2
build_cmake_lib ngtcp2 "$BUILD_DIR/ngtcp2-$NGTCP2_VER" \
  -DENABLE_OPENSSL=ON -DENABLE_LIB_ONLY=ON -DBUILD_TESTING=OFF

export PKG_CONFIG_PATH="$(kotv_native_path "$PREFIX/lib/pkgconfig")${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
pkg-config --exists libnghttp3 || { echo "ERROR: libnghttp3.pc missing" >&2; ls "$PREFIX/lib/pkgconfig" >&2; exit 1; }
pkg-config --exists libngtcp2 || { echo "ERROR: libngtcp2.pc missing" >&2; exit 1; }
if ! pkg-config --exists libngtcp2_crypto_ossl 2>/dev/null \
  && ! pkg-config --exists libngtcp2_crypto_quictls 2>/dev/null; then
  echo "ERROR: ngtcp2 OpenSSL crypto helper pc missing" >&2
  ls -la "$PREFIX/lib/pkgconfig"/libngtcp2* >&2 || true
  exit 1
fi
echo "ok nghttp3=$(pkg-config --modversion libnghttp3) ngtcp2=$(pkg-config --modversion libngtcp2)"
