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
  # tmp 名勿匹配 ${name}-*，否则 find 会命中 tmp 自身（无顶层 CMakeLists）
  local tmp="$BUILD_DIR/_extract-${name}-${ver}"
  # 发行包含 git submodule（nghttp3→sfparse；ngtcp2→urlparse）。GitHub archive 不含。
  local need_extra=""
  case "$name" in
    nghttp3) need_extra="lib/sfparse/sfparse.c" ;;
    ngtcp2) need_extra="crypto/includes/ngtcp2/ngtcp2_crypto.h" ;;
  esac
  if [[ -f "$src/CMakeLists.txt" ]]; then
    if [[ -z "$need_extra" || -f "$src/$need_extra" ]]; then
      return 0
    fi
    echo "WARN: $src incomplete (missing $need_extra); re-fetch release tarball" >&2
  fi
  rm -rf "$src" "$tmp"
  curl -fsSL -o "$tarball" \
    "https://github.com/${repo}/releases/download/v${ver}/${name}-${ver}.tar.gz"
  mkdir -p "$tmp"
  tar -xzf "$tarball" -C "$tmp"
  local found
  found="$(find "$tmp" -maxdepth 1 -mindepth 1 -type d -name "${name}-*" | head -1 || true)"
  if [[ -z "$found" || ! -f "$found/CMakeLists.txt" ]]; then
    echo "ERROR: extract $name v$ver missing CMakeLists.txt" >&2
    ls -la "$tmp" >&2 || true
    [[ -n "$found" ]] && ls -la "$found" >&2 || true
    exit 1
  fi
  if [[ -n "$need_extra" && ! -f "$found/$need_extra" ]]; then
    echo "ERROR: $name release tarball missing $need_extra (submodule)" >&2
    ls -la "$found/$(dirname "$need_extra")" >&2 || true
    exit 1
  fi
  mv "$found" "$src"
  rm -rf "$tmp"
  [[ -f "$src/CMakeLists.txt" ]] || {
    echo "ERROR: $src still missing CMakeLists.txt after move" >&2
    ls -la "$src" >&2 || true
    exit 1
  }
}

build_cmake_lib() {
  local name="$1"
  local src="$2"
  local build="$BUILD_DIR/$name-build"
  shift 2
  rm -rf "$build"
  mkdir -p "$build"
  echo "==> build $name → $pref"
  [[ -f "$src/CMakeLists.txt" ]] || {
    echo "ERROR: $src has no CMakeLists.txt" >&2
    ls -la "$src" >&2 || true
    exit 1
  }
  local -a cmake_cmd=(
    cmake -S "$src" -B "$build" -G "$gen"
    -DCMAKE_INSTALL_PREFIX="$pref"
    -DCMAKE_BUILD_TYPE=Release
    -DBUILD_SHARED_LIBS=ON
    -DCMAKE_PREFIX_PATH="$pref"
  )
  if kotv_is_windows_build; then
    cmake_cmd+=(
      -DCMAKE_C_COMPILER=gcc
      -DCMAKE_CXX_COMPILER=g++
      -DCMAKE_MAKE_PROGRAM=mingw32-make
      -DCMAKE_C_FLAGS="${WIN7_CFLAGS}"
      -DCMAKE_CXX_FLAGS="${WIN7_CFLAGS}"
    )
  fi
  while IFS= read -r a; do
    [[ -n "$a" ]] && cmake_cmd+=("$a")
  done < <(kotv_cmake_macos_arch_args)
  # 勿用空数组 "${winflags[@]}"：macOS bash 3.2 + set -u 会 unbound
  "${cmake_cmd[@]}" "$@"
  cmake --build "$build" -j"$JOBS"
  cmake --install "$build"
}

fetch_extract nghttp3 "$NGHTTP3_VER" ngtcp2/nghttp3
build_cmake_lib nghttp3 "$BUILD_DIR/nghttp3-$NGHTTP3_VER" \
  -DENABLE_LIB_ONLY=ON -DENABLE_SHARED_LIB=ON -DENABLE_STATIC_LIB=ON -DBUILD_TESTING=OFF

export PKG_CONFIG_PATH="$(kotv_native_path "$PREFIX/lib/pkgconfig")${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

fetch_extract ngtcp2 "$NGTCP2_VER" ngtcp2/ngtcp2
build_cmake_lib ngtcp2 "$BUILD_DIR/ngtcp2-$NGTCP2_VER" \
  -DENABLE_OPENSSL=ON -DENABLE_LIB_ONLY=ON -DENABLE_SHARED_LIB=ON -DENABLE_STATIC_LIB=ON -DBUILD_TESTING=OFF

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
