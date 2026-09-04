#!/usr/bin/env bash
# 桌面网络栈（全平台源码对齐，Win7 可用）：
#   FFmpeg 播流：HTTPS / HTTP/2(nghttp2) / RTSP / RTMP
#   mpv libcurl：HTTP/1.1 + HTTP/2 + HTTP/3（OpenSSL + nghttp2 + ngtcp2 + nghttp3，CMake）
#
# 不用 MSYS2 预编译包（不支持 Win7）。Windows 用 CMake 编 curl，避开 autotools+PATH 空格。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=kotv-win-build-env.sh
source "$ROOT/scripts/kotv-win-build-env.sh"
BUILD_DIR="${KOTV_MPV_BUILD_DIR:-$ROOT/.build/desktop-mpv}"
PREFIX="${KOTV_DESKTOP_FFMPEG_PREFIX:-$BUILD_DIR/prefix}"
JOBS="${KOTV_MPV_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "${NUMBER_OF_PROCESSORS:-4}")}"
CURL_VER="${KOTV_CURL_VER:-8.14.1}"
WIN7_CFLAGS="$(kotv_win7_cflags)"

kotv_native_path() {
  local p="$1"
  if kotv_is_windows_build && command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$p"
  else
    printf '%s' "$p"
  fi
}

mkdir -p "$PREFIX/lib/pkgconfig" "$PREFIX/include" "$PREFIX/lib" "$PREFIX/bin" "$BUILD_DIR"
export PKG_CONFIG_PATH="$(kotv_native_path "$PREFIX/lib/pkgconfig")${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

write_simple_curl_pc() {
  local libs="$1"
  local cflags="${2:-}"
  local ver="${3:-$CURL_VER}"
  local pref
  pref="$(kotv_native_path "$PREFIX")"
  {
    echo "prefix=$pref"
    echo "exec_prefix=\${prefix}"
    echo "libdir=\${prefix}/lib"
    echo "includedir=\${prefix}/include"
    echo "Name: libcurl"
    echo "Description: KOTV libcurl (HTTP/2+HTTP/3, Win7-safe source build)"
    echo "Version: $ver"
    echo "Libs: $libs"
    [[ -n "$cflags" ]] && echo "Cflags: $cflags"
  } >"$PREFIX/lib/pkgconfig/libcurl.pc"
}

curl_features_have_http3() {
  local bin="$1"
  [[ -x "$bin" ]] || return 1
  "$bin" -V 2>/dev/null | grep -Eiq 'HTTP3|nghttp3|ngtcp2'
}

# 已缓存且带 HTTP3
if [[ -f "$PREFIX/lib/pkgconfig/libcurl.pc" ]] \
  && { [[ -f "$PREFIX/lib/libcurl.a" || -f "$PREFIX/lib/libcurl.dll.a" || -f "$PREFIX/bin/libcurl-4.dll" || -f "$PREFIX/bin/libcurl.dll" \
      || -f "$PREFIX/lib/libcurl.dylib" || -f "$PREFIX/lib/libcurl.so" ]]; }; then
  bin=""
  for c in "$PREFIX/bin/curl.exe" "$PREFIX/bin/curl"; do
    [[ -x "$c" ]] && bin="$c" && break
  done
  if [[ -n "$bin" ]] && curl_features_have_http3 "$bin"; then
    echo "ok cached libcurl $(pkg-config --modversion libcurl 2>/dev/null || echo present) (HTTP3)"
    exit 0
  fi
  if [[ -z "$bin" ]]; then
    echo "ok cached libcurl pc (no curl binary to probe)"
    exit 0
  fi
  echo "WARN: cached curl lacks HTTP3; rebuilding" >&2
fi

chmod +x "$ROOT/scripts/ensure-desktop-nghttp2.sh"
chmod +x "$ROOT/scripts/ensure-desktop-ngtcp2-stack.sh"
"$ROOT/scripts/ensure-desktop-nghttp2.sh"
"$ROOT/scripts/ensure-desktop-ngtcp2-stack.sh"
export PKG_CONFIG_PATH="$(kotv_native_path "$PREFIX/lib/pkgconfig")${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

need() { command -v "$1" >/dev/null || { echo "need $1" >&2; exit 1; }; }
need cmake
need curl
need tar
kotv_clean_win_path "$BUILD_DIR/bin"

src="$BUILD_DIR/curl-$CURL_VER"
tarball="$BUILD_DIR/curl-$CURL_VER.tar.gz"
if [[ ! -f "$src/CMakeLists.txt" ]]; then
  curl -fsSL -o "$tarball" \
    "https://curl.se/download/curl-${CURL_VER}.tar.gz" \
    || curl -fsSL -o "$tarball" \
      "https://github.com/curl/curl/releases/download/curl-$(echo "$CURL_VER" | tr . _)/curl-${CURL_VER}.tar.gz"
  rm -rf "$src"
  tar -xzf "$tarball" -C "$BUILD_DIR"
fi

pref="$(kotv_native_path "$PREFIX")"
build="$BUILD_DIR/curl-build"
rm -rf "$build"
mkdir -p "$build"

gen=Ninja
command -v ninja >/dev/null 2>&1 || gen="Unix Makefiles"
if kotv_is_windows_build; then
  gen="MinGW Makefiles"
fi

echo "==> build libcurl $CURL_VER (OpenSSL + nghttp2 + ngtcp2/nghttp3) → $pref"
cmake_args=(
  -DCMAKE_INSTALL_PREFIX="$pref"
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_PREFIX_PATH="$pref"
  -DBUILD_SHARED_LIBS=ON
  -DBUILD_CURL_EXE=ON
  -DBUILD_TESTING=OFF
  -DCURL_USE_OPENSSL=ON
  -DCURL_USE_SCHANNEL=OFF
  -DCURL_DISABLE_LDAP=ON
  -DCURL_DISABLE_LDAPS=ON
  -DUSE_NGHTTP2=ON
  -DUSE_NGTCP2=ON
  -DCURL_BROTLI=OFF
  -DCURL_ZSTD=OFF
  -DCURL_USE_LIBPSL=OFF
  -DCURL_USE_LIBSSH2=OFF
)
if kotv_is_windows_build; then
  cmake_args+=(
    -DCMAKE_C_FLAGS="${WIN7_CFLAGS} -DNGHTTP2_STATICLIB"
    -DCMAKE_CXX_FLAGS="${WIN7_CFLAGS}"
    -DCURL_CA_BUNDLE=none
    -DCURL_CA_PATH=none
  )
fi

cmake -S "$src" -B "$build" -G "$gen" "${cmake_args[@]}"
cmake --build "$build" -j"$JOBS"
cmake --install "$build"

export PKG_CONFIG_PATH="$(kotv_native_path "$PREFIX/lib/pkgconfig")${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

libs="-L${pref}/lib -lcurl"
if kotv_is_windows_build; then
  libs="-L${pref}/lib -lcurl -lws2_32 -lbcrypt -lcrypt32"
fi
write_simple_curl_pc "$libs" "-I${pref}/include" "$CURL_VER"

if ! pkg-config --exists libcurl; then
  echo "ERROR: libcurl.pc missing" >&2
  exit 1
fi

bin=""
for c in "$PREFIX/bin/curl.exe" "$PREFIX/bin/curl"; do
  [[ -x "$c" ]] && bin="$c" && break
done
if [[ -n "$bin" ]]; then
  echo "==> curl -V:"
  "$bin" -V || true
  if ! curl_features_have_http3 "$bin"; then
    echo "ERROR: built curl missing HTTP3 in -V output" >&2
    "$bin" -V >&2 || true
    exit 1
  fi
  if ! "$bin" -V 2>/dev/null | grep -Eiq 'HTTP2|nghttp2'; then
    echo "ERROR: built curl missing HTTP2 in -V output" >&2
    exit 1
  fi
fi

echo "ok libcurl $(pkg-config --modversion libcurl) (HTTP/2 + HTTP/3, source)"
