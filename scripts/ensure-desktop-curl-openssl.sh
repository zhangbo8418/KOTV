#!/usr/bin/env bash
# 桌面 libmpv 网络栈：
#   macOS  — 系统 libcurl + FFmpeg SecureTransport（dyld 共享缓存里可能没有 /usr/lib/libcurl*.dylib）
#   Windows — 前缀静态 libcurl（Schannel），FFmpeg --enable-schannel（勿编 OpenSSL：MSYS perl 缺模块）
#   Linux  — 系统 openssl+curl，否则编进 PREFIX
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${KOTV_MPV_BUILD_DIR:-$ROOT/.build/desktop-mpv}"
PREFIX="${KOTV_DESKTOP_FFMPEG_PREFIX:-$BUILD_DIR/prefix}"
JOBS="${KOTV_MPV_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "${NUMBER_OF_PROCESSORS:-4}")}"
OPENSSL_VER="${KOTV_OPENSSL_VER:-3.0.15}"
CURL_VER="${KOTV_CURL_VER:-8.11.1}"

kotv_is_windows_build() {
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
  esac
  [[ "${OS:-}" == "Windows_NT" ]]
}

kotv_native_path() {
  local p="$1"
  if kotv_is_windows_build && command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$p"
  else
    printf '%s' "$p"
  fi
}

need() { command -v "$1" >/dev/null || { echo "need $1" >&2; exit 1; }; }

mkdir -p "$PREFIX/lib/pkgconfig" "$PREFIX/include" "$PREFIX/lib" "$BUILD_DIR"
export PKG_CONFIG_PATH="$(kotv_native_path "$PREFIX/lib/pkgconfig")${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

if kotv_is_windows_build; then
  if [[ -x "$BUILD_DIR/bin/pkg-config" ]]; then
    export PATH="$BUILD_DIR/bin:$PATH"
    export PKG_CONFIG="$BUILD_DIR/bin/pkg-config"
  fi
fi

have_openssl_pc() {
  pkg-config --exists openssl 2>/dev/null || pkg-config --exists libssl 2>/dev/null
}

have_curl_pc() {
  pkg-config --exists libcurl 2>/dev/null
}

# macOS：SDK/系统自带 curl；新系统 dyld 共享缓存可能没有 /usr/lib/libcurl*.dylib。
# meson -Dlibcurl=enabled 需要 libcurl.pc —— 优先 Homebrew curl，否则写一份链 -lcurl 的桩 .pc。
if [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
  if ! have_curl_pc && command -v brew >/dev/null 2>&1; then
    brew_curl="$(brew --prefix curl 2>/dev/null || true)"
    if [[ -n "$brew_curl" && -d "$brew_curl/lib/pkgconfig" ]]; then
      export PKG_CONFIG_PATH="$brew_curl/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    fi
  fi
  if have_curl_pc; then
    echo "ok macOS network: libcurl=$(pkg-config --modversion libcurl) (+ FFmpeg SecureTransport)"
    exit 0
  fi
  cat >"$PREFIX/lib/pkgconfig/libcurl.pc" <<EOF
prefix=/usr
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: libcurl
Description: macOS SDK / system libcurl (KOTV stub pc)
Version: 8.0.0
Libs: -lcurl
Cflags:
EOF
  export PKG_CONFIG_PATH="$(kotv_native_path "$PREFIX/lib/pkgconfig")${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  have_curl_pc || { echo "ERROR: failed to install stub libcurl.pc" >&2; exit 1; }
  echo "ok macOS network: stub libcurl.pc → -lcurl (+ FFmpeg SecureTransport)"
  exit 0
fi

build_curl_schannel() {
  if [[ -f "$PREFIX/lib/libcurl.a" ]] && have_curl_pc; then
    echo "ok cached libcurl (schannel) in PREFIX"
    return 0
  fi
  need curl
  need tar
  local src="$BUILD_DIR/curl-$CURL_VER"
  local tarball="$BUILD_DIR/curl-$CURL_VER.tar.gz"
  if [[ ! -f "$src/configure" ]]; then
    curl -fsSL -o "$tarball" "https://curl.se/download/curl-$CURL_VER.tar.gz"
    rm -rf "$src"
    tar -xzf "$tarball" -C "$BUILD_DIR"
  fi
  cd "$src"
  local pref
  pref="$(kotv_native_path "$PREFIX")"
  echo "==> build libcurl $CURL_VER (Windows Schannel, no OpenSSL) → $pref"
  export PKG_CONFIG_PATH="$(kotv_native_path "$PREFIX/lib/pkgconfig")"
  # 不可同时 --without-ssl 与 --with-schannel（curl configure 会直接报错）。
  ./configure \
    --prefix="$pref" \
    --host=x86_64-w64-mingw32 \
    --disable-shared \
    --enable-static \
    --with-schannel \
    --without-zlib \
    --without-libpsl \
    --without-brotli \
    --without-zstd \
    --without-libidn2 \
    --without-nghttp2 \
    --disable-ldap \
    --disable-rtsp \
    --disable-manual
  local MAKE="${KOTV_MAKE:-mingw32-make}"
  command -v "$MAKE" >/dev/null || MAKE=make
  "$MAKE" -j"$JOBS"
  "$MAKE" install
  have_curl_pc || { echo "ERROR: libcurl pkg-config missing after schannel build" >&2; exit 1; }
  echo "ok libcurl $(pkg-config --modversion libcurl) (schannel)"
}

# Windows：只编 Schannel curl，不碰 OpenSSL（避免 MSYS perl Locale::Maketext）。
if kotv_is_windows_build; then
  build_curl_schannel
  echo "ok Windows network: libcurl+Schannel (FFmpeg uses --enable-schannel)"
  exit 0
fi

# Linux：优先系统开发包。
if have_openssl_pc && have_curl_pc; then
  echo "ok Linux network: system openssl=$(pkg-config --modversion openssl 2>/dev/null || echo ?) curl=$(pkg-config --modversion libcurl 2>/dev/null || echo ?)"
  exit 0
fi
echo "==> Linux: system openssl/curl missing; building into PREFIX"

build_openssl() {
  if [[ -f "$PREFIX/lib/libssl.a" ]] && [[ -f "$PREFIX/include/openssl/ssl.h" ]] && have_openssl_pc; then
    echo "ok cached OpenSSL in PREFIX"
    return 0
  fi
  need perl
  need curl
  need tar
  local src="$BUILD_DIR/openssl-$OPENSSL_VER"
  local tarball="$BUILD_DIR/openssl-$OPENSSL_VER.tar.gz"
  if [[ ! -d "$src" ]] || [[ ! -f "$src/Configure" ]]; then
    curl -fsSL -o "$tarball" "https://www.openssl.org/source/openssl-$OPENSSL_VER.tar.gz" \
      || curl -fsSL -o "$tarball" "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VER/openssl-$OPENSSL_VER.tar.gz"
    rm -rf "$src"
    tar -xzf "$tarball" -C "$BUILD_DIR"
  fi
  cd "$src"
  local pref
  pref="$(kotv_native_path "$PREFIX")"
  echo "==> build OpenSSL $OPENSSL_VER → $pref"
  ./Configure linux-x86_64 no-shared no-tests no-zlib --prefix="$pref" --libdir=lib
  make -j"$JOBS"
  make install_sw
  if [[ ! -f "$PREFIX/lib/pkgconfig/openssl.pc" ]] && [[ -f "$PREFIX/lib/pkgconfig/libssl.pc" ]]; then
    cp -f "$PREFIX/lib/pkgconfig/libssl.pc" "$PREFIX/lib/pkgconfig/openssl.pc"
  fi
  have_openssl_pc || { echo "ERROR: OpenSSL pkg-config missing after install" >&2; exit 1; }
  echo "ok OpenSSL $(pkg-config --modversion openssl 2>/dev/null || true)"
}

build_curl_openssl() {
  if [[ -f "$PREFIX/lib/libcurl.a" ]] && have_curl_pc; then
    echo "ok cached libcurl in PREFIX"
    return 0
  fi
  need curl
  need tar
  local src="$BUILD_DIR/curl-$CURL_VER"
  local tarball="$BUILD_DIR/curl-$CURL_VER.tar.gz"
  if [[ ! -f "$src/configure" ]]; then
    curl -fsSL -o "$tarball" "https://curl.se/download/curl-$CURL_VER.tar.gz"
    rm -rf "$src"
    tar -xzf "$tarball" -C "$BUILD_DIR"
  fi
  cd "$src"
  local pref
  pref="$(kotv_native_path "$PREFIX")"
  echo "==> build libcurl $CURL_VER (openssl) → $pref"
  export PKG_CONFIG_PATH="$(kotv_native_path "$PREFIX/lib/pkgconfig")${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  ./configure \
    --prefix="$pref" \
    --disable-shared \
    --enable-static \
    --with-openssl="$pref" \
    --without-zlib \
    --without-libpsl \
    --without-brotli \
    --without-zstd \
    --without-libidn2 \
    --without-nghttp2 \
    --disable-ldap \
    --disable-rtsp \
    --disable-manual
  make -j"$JOBS"
  make install
  have_curl_pc || { echo "ERROR: libcurl pkg-config missing after install" >&2; exit 1; }
  echo "ok libcurl $(pkg-config --modversion libcurl)"
}

build_openssl
build_curl_openssl
echo "ok desktop curl+openssl prefix ready"
