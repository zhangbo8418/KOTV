#!/usr/bin/env bash
# 桌面 libmpv 网络栈（HTTPS/302）：
#   Windows — 不编 libcurl（MinGW+autotools 易被 PATH 空格打爆）；FFmpeg --enable-schannel 即可
#   macOS   — PREFIX 内写无 Requires.private 的 libcurl.pc（链系统/brew 的 -lcurl）
#   Linux   — 系统 libcurl/openssl；可选把 .pc 镜像进 PREFIX 供 LIBDIR=PREFIX 的 meson
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${KOTV_MPV_BUILD_DIR:-$ROOT/.build/desktop-mpv}"
PREFIX="${KOTV_DESKTOP_FFMPEG_PREFIX:-$BUILD_DIR/prefix}"

kotv_is_windows_build() {
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
  esac
  [[ "${OS:-}" == "Windows_NT" ]]
}

mkdir -p "$PREFIX/lib/pkgconfig" "$PREFIX/include" "$PREFIX/lib" "$BUILD_DIR"

have_curl_pc() {
  pkg-config --exists libcurl 2>/dev/null
}

# Windows：只依赖 FFmpeg Schannel HTTPS；不在此编 curl。
if kotv_is_windows_build; then
  echo "ok Windows network: skip libcurl build (use FFmpeg --enable-schannel for HTTPS/302)"
  exit 0
fi

# 写一份「无 Requires.private」的 pc，避免 PKG_CONFIG_LIBDIR=PREFIX 时解析 brew 私有依赖失败。
write_simple_curl_pc() {
  local libs="$1"
  local cflags="${2:-}"
  {
    echo "Name: libcurl"
    echo "Description: KOTV simple libcurl pc (no Requires.private)"
    echo "Version: 8.0.0"
    echo "Libs: $libs"
    [[ -n "$cflags" ]] && echo "Cflags: $cflags"
  } >"$PREFIX/lib/pkgconfig/libcurl.pc"
}

if [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
  brew_curl=""
  if command -v brew >/dev/null 2>&1; then
    brew_curl="$(brew --prefix curl 2>/dev/null || true)"
  fi
  if [[ -n "$brew_curl" && -f "$brew_curl/lib/libcurl.dylib" ]]; then
    write_simple_curl_pc "-L${brew_curl}/lib -lcurl" "-I${brew_curl}/include"
    echo "ok macOS network: simple pc → ${brew_curl} (+ FFmpeg SecureTransport)"
    exit 0
  fi
  write_simple_curl_pc "-lcurl" ""
  echo "ok macOS network: simple pc → -lcurl (+ FFmpeg SecureTransport)"
  exit 0
fi

# Linux：系统包；把 .pc 拷到 PREFIX（去掉/忽略私有依赖问题：直接写 simple）。
if have_curl_pc; then
  ver="$(pkg-config --modversion libcurl 2>/dev/null || echo 8.0.0)"
  libs="$(pkg-config --libs libcurl 2>/dev/null || echo '-lcurl')"
  cflags="$(pkg-config --cflags libcurl 2>/dev/null || true)"
  write_simple_curl_pc "$libs" "$cflags"
  echo "ok Linux network: simple pc from system curl=$ver (+ openssl for FFmpeg)"
  exit 0
fi

echo "ERROR: Linux missing libcurl (apt: libcurl4-openssl-dev)" >&2
exit 1
