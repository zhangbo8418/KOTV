#!/usr/bin/env bash
# 桌面 libmpv 网络栈：
#   macOS  — brew/stub libcurl.pc + FFmpeg SecureTransport
#   Windows — 前缀静态 libcurl（Schannel）+ FFmpeg --enable-schannel
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

have_curl_pc() {
  pkg-config --exists libcurl 2>/dev/null
}

have_openssl_pc() {
  pkg-config --exists openssl 2>/dev/null || pkg-config --exists libssl 2>/dev/null
}

# macOS：把可用的 libcurl.pc 落进 PREFIX（父脚本常设 PKG_CONFIG_LIBDIR=PREFIX，会挡住 brew）。
if [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
  if [[ -f "$PREFIX/lib/pkgconfig/libcurl.pc" ]] && have_curl_pc; then
    echo "ok macOS network: prefix libcurl.pc ($(pkg-config --modversion libcurl)) (+ SecureTransport)"
    exit 0
  fi
  brew_curl=""
  if command -v brew >/dev/null 2>&1; then
    brew_curl="$(brew --prefix curl 2>/dev/null || true)"
  fi
  if [[ -n "$brew_curl" && -f "$brew_curl/lib/pkgconfig/libcurl.pc" ]]; then
    cp -f "$brew_curl/lib/pkgconfig/libcurl.pc" "$PREFIX/lib/pkgconfig/libcurl.pc"
    # 若 pc 含 brew 绝对路径，原样可用；meson 只从 PREFIX LIBDIR 找得到。
    export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    # 临时去掉 LIBDIR 限制以便校验；调用方会再设回 PREFIX。
    old_libdir="${PKG_CONFIG_LIBDIR:-}"
    unset PKG_CONFIG_LIBDIR || true
    if have_curl_pc; then
      [[ -n "$old_libdir" ]] && export PKG_CONFIG_LIBDIR="$old_libdir"
      echo "ok macOS network: copied brew libcurl.pc ($(pkg-config --modversion libcurl)) → PREFIX"
      exit 0
    fi
    [[ -n "$old_libdir" ]] && export PKG_CONFIG_LIBDIR="$old_libdir"
  fi
  cat >"$PREFIX/lib/pkgconfig/libcurl.pc" <<'EOF'
Name: libcurl
Description: macOS SDK / system libcurl (KOTV stub)
Version: 8.0.0
Libs: -lcurl
Cflags:
EOF
  echo "ok macOS network: stub libcurl.pc → -lcurl (+ SecureTransport)"
  exit 0
fi

# Windows：去掉 PATH 里带空格的条目（VS/Git「C:/Program Files/…」会让 libtool Error 127）。
kotv_win_sanitize_path() {
  local cleaned="" part
  local gcc_bin=""
  if command -v gcc >/dev/null 2>&1; then
    gcc_bin="$(cd "$(dirname "$(command -v gcc)")" && pwd)"
  fi
  IFS=':' read -ra _parts <<<"$PATH"
  for part in "${_parts[@]}"; do
    [[ -z "$part" ]] && continue
    case "$part" in
      *[\ ]*|*[Pp]rogram*[Ff]iles*) continue ;;
    esac
    if [[ -z "$cleaned" ]]; then cleaned="$part"; else cleaned="$cleaned:$part"; fi
  done
  if [[ -n "$gcc_bin" ]]; then
    export PATH="$gcc_bin:/usr/bin:/bin:$cleaned"
  else
    export PATH="/usr/bin:/bin:$cleaned"
  fi
  export CC=gcc CXX=g++ AR=ar RANLIB=ranlib NM=nm STRIP=strip LD=ld
  unset CCC COMPILER_PATH INCLUDE LIB LIBPATH VCINSTALLDIR VSINSTALLDIR WindowsSdkDir 2>/dev/null || true
}

build_curl_schannel() {
  if [[ -f "$PREFIX/lib/libcurl.a" ]] && [[ -f "$PREFIX/lib/pkgconfig/libcurl.pc" ]]; then
    echo "ok cached libcurl (schannel) in PREFIX"
    return 0
  fi
  need curl
  need tar
  need gcc
  kotv_win_sanitize_path
  if kotv_is_windows_build; then
    if [[ -x "$BUILD_DIR/bin/pkg-config" ]]; then
      export PATH="$BUILD_DIR/bin:$PATH"
      export PKG_CONFIG="$BUILD_DIR/bin/pkg-config"
    fi
  fi
  local src="$BUILD_DIR/curl-$CURL_VER"
  local tarball="$BUILD_DIR/curl-$CURL_VER.tar.gz"
  if [[ ! -f "$src/configure" ]]; then
    curl -fsSL -o "$tarball" "https://curl.se/download/curl-$CURL_VER.tar.gz"
    rm -rf "$src"
    tar -xzf "$tarball" -C "$BUILD_DIR"
  fi
  cd "$src"
  # 旧失败配置残留；强制重配。
  [[ -f Makefile ]] && make distclean >/dev/null 2>&1 || true
  local pref
  pref="$(kotv_native_path "$PREFIX")"
  echo "==> build libcurl $CURL_VER (Windows Schannel) CC=$(command -v gcc) → $pref"
  export PKG_CONFIG_PATH="$(kotv_native_path "$PREFIX/lib/pkgconfig")"
  # 不可同时 --without-ssl 与 --with-schannel。
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
    --disable-manual \
    CC=gcc \
    CXX=g++
  local MAKE="${KOTV_MAKE:-mingw32-make}"
  command -v "$MAKE" >/dev/null || MAKE=make
  # 单线程更易定位；仍用 JOBS，但 CC 显式无空格。
  "$MAKE" -j"$JOBS" CC=gcc CXX=g++
  "$MAKE" install
  [[ -f "$PREFIX/lib/libcurl.a" ]] || { echo "ERROR: libcurl.a missing after install" >&2; exit 1; }
  [[ -f "$PREFIX/lib/pkgconfig/libcurl.pc" ]] || { echo "ERROR: libcurl.pc missing after install" >&2; exit 1; }
  echo "ok libcurl installed (schannel)"
}

if kotv_is_windows_build; then
  build_curl_schannel
  echo "ok Windows network: libcurl+Schannel (FFmpeg uses --enable-schannel)"
  exit 0
fi

# Linux
export PKG_CONFIG_PATH="$(kotv_native_path "$PREFIX/lib/pkgconfig")${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
if have_openssl_pc && have_curl_pc; then
  echo "ok Linux network: system openssl=$(pkg-config --modversion openssl 2>/dev/null || echo ?) curl=$(pkg-config --modversion libcurl 2>/dev/null || echo ?)"
  exit 0
fi
echo "==> Linux: system openssl/curl missing; building into PREFIX"

build_openssl() {
  if [[ -f "$PREFIX/lib/libssl.a" ]] && [[ -f "$PREFIX/include/openssl/ssl.h" ]]; then
    echo "ok cached OpenSSL in PREFIX"
    return 0
  fi
  need perl
  need curl
  need tar
  local src="$BUILD_DIR/openssl-$OPENSSL_VER"
  local tarball="$BUILD_DIR/openssl-$OPENSSL_VER.tar.gz"
  if [[ ! -f "$src/Configure" ]]; then
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
  echo "ok OpenSSL"
}

build_curl_openssl() {
  if [[ -f "$PREFIX/lib/libcurl.a" ]] && [[ -f "$PREFIX/lib/pkgconfig/libcurl.pc" ]]; then
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
  echo "ok libcurl"
}

build_openssl
build_curl_openssl
echo "ok desktop curl+openssl prefix ready"
