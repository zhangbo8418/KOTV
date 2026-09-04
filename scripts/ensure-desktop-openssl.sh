#!/usr/bin/env bash
# 把 OpenSSL（≥3.5，带 QUIC）源码编进 PREFIX，供 ngtcp2/curl HTTP/3。
# Windows：./Configure mingw64 + Win7 宏（不用 MSYS2 预编译包，那些不支持 Win7）。
# macOS/Linux：brew/系统优先，否则 Configure。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=kotv-win-build-env.sh
source "$ROOT/scripts/kotv-win-build-env.sh"
BUILD_DIR="${KOTV_MPV_BUILD_DIR:-$ROOT/.build/desktop-mpv}"
PREFIX="${KOTV_DESKTOP_FFMPEG_PREFIX:-$BUILD_DIR/prefix}"
JOBS="${KOTV_MPV_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "${NUMBER_OF_PROCESSORS:-4}")}"
OPENSSL_VER="${KOTV_OPENSSL_VER:-3.5.2}"
WIN7_CFLAGS="$(kotv_win7_cflags)"

kotv_native_path() {
  local p="$1"
  if kotv_is_windows_build && command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$p"
  else
    printf '%s' "$p"
  fi
}

openssl_ver_ok() {
  local v
  v="$(pkg-config --modversion openssl 2>/dev/null || pkg-config --modversion libssl 2>/dev/null || true)"
  [[ -n "$v" ]] || return 1
  python3 - "$v" <<'PY'
import sys
v = sys.argv[1].split("+")[0]
parts = []
for p in v.split("."):
    try:
        parts.append(int("".join(ch for ch in p if ch.isdigit()) or "0"))
    except ValueError:
        parts.append(0)
while len(parts) < 3:
    parts.append(0)
sys.exit(0 if tuple(parts[:3]) >= (3, 5, 0) else 1)
PY
}

openssl_has_quic_api() {
  # ngtcp2 OpenSSL backend 需要 SSL_set_quic_tls_cbs（OpenSSL ≥3.5 + enable-quic）
  local lib h
  for lib in \
    "$PREFIX/lib/libssl.dylib" "$PREFIX/lib/libssl.so" "$PREFIX/lib/libssl.so.3" \
    "$PREFIX/lib/libssl.dll.a" "$PREFIX/bin/libssl-3-x64.dll" "$PREFIX/bin/libssl-3.dll" \
    "$PREFIX/lib/libssl-3.dll"; do
    [[ -e "$lib" ]] || continue
    if nm -gU "$lib" 2>/dev/null | grep -q 'SSL_set_quic_tls_cbs' \
      || nm -D "$lib" 2>/dev/null | grep -q 'SSL_set_quic_tls_cbs' \
      || strings "$lib" 2>/dev/null | grep -q 'SSL_set_quic_tls_cbs'; then
      return 0
    fi
  done
  for h in "$PREFIX/include/openssl/ssl.h"; do
    [[ -f "$h" ]] && grep -q 'SSL_set_quic_tls_cbs' "$h" 2>/dev/null && return 0
  done
  return 1
}

# OpenSSL Configure 需要 Locale::Maketext + ExtUtils::MakeMaker。
# Git Bash/MinGW 下必须用 Unix 路径风格的 perl；Strawberry 整库 PERL5LIB 会污染 Config.pm。
kotv_vendor_cpan_lib() {
  local local_lib="$1" dist="$2" url="$3" marker="${4:-}"
  local tmp="$BUILD_DIR/_cpan-$dist"
  mkdir -p "$local_lib"
  if [[ -n "$marker" && -f "$local_lib/$marker" ]]; then
    return 0
  fi
  rm -rf "$tmp"
  mkdir -p "$tmp"
  curl -fsSL -o "$tmp/$dist.tar.gz" "$url" || return 1
  tar -xzf "$tmp/$dist.tar.gz" -C "$tmp"
  local found
  found="$(find "$tmp" -maxdepth 1 -mindepth 1 -type d -name "${dist}-*" | head -1 || true)"
  [[ -n "$found" && -d "$found/lib" ]] || return 1
  cp -R "$found/lib/." "$local_lib/"
  rm -rf "$tmp"
  return 0
}

ensure_openssl_perl() {
  local p candidates=() local_lib="$BUILD_DIR/perl5"
  mkdir -p "$local_lib"
  if kotv_is_windows_build; then
    candidates+=(/usr/bin/perl /bin/perl)
    unset PERL5LIB || true
  fi
  candidates+=("$(command -v perl 2>/dev/null || true)")

  # 纯 Perl 模块进本地 lib（不含 Config.pm）；OpenSSL Configure 还要 Simple + MakeMaker
  kotv_vendor_cpan_lib "$local_lib" Locale-Maketext \
    "https://cpan.metacpan.org/authors/id/T/TO/TODDR/Locale-Maketext-1.33.tar.gz" \
    "Locale/Maketext.pm" || true
  kotv_vendor_cpan_lib "$local_lib" Locale-Maketext-Simple \
    "https://cpan.metacpan.org/authors/id/J/JE/JESSE/Locale-Maketext-Simple-0.21.tar.gz" \
    "Locale/Maketext/Simple.pm" || true
  kotv_vendor_cpan_lib "$local_lib" ExtUtils-MakeMaker \
    "https://cpan.metacpan.org/authors/id/B/BI/BINGOS/ExtUtils-MakeMaker-7.70.tar.gz" \
    "ExtUtils/MakeMaker.pm" || true
  if kotv_is_windows_build && [[ ! -f "$local_lib/Locale/Maketext.pm" ]]; then
    local src
    for src in /c/Strawberry/perl/lib /c/strawberry/perl/lib; do
      [[ -d "$src/Locale" ]] || continue
      cp -R "$src/Locale" "$local_lib/" 2>/dev/null || true
      [[ -d "$src/I18N" ]] && cp -R "$src/I18N" "$local_lib/" 2>/dev/null || true
      break
    done
  fi
  export PERL5LIB="$local_lib"

  for p in "${candidates[@]}"; do
    [[ -n "$p" && -x "$p" ]] || continue
    case "$p" in *[Ss]trawberry*) continue ;; esac
    if "$p" -MLocale::Maketext -e "1" 2>/dev/null \
      && "$p" -MLocale::Maketext::Simple -e "1" 2>/dev/null \
      && "$p" -MExtUtils::MakeMaker -e "1" 2>/dev/null; then
      export PERL="$p"
      echo "ok perl for OpenSSL: $PERL (PERL5LIB=$PERL5LIB)"
      return 0
    fi
  done
  echo "ERROR: need MSYS/Git perl + Locale::Maketext(+Simple) + ExtUtils::MakeMaker" >&2
  ls -laR "$local_lib" 2>/dev/null | head -80 >&2 || true
  for p in "${candidates[@]}"; do
    [[ -n "$p" && -x "$p" ]] || continue
    case "$p" in *[Ss]trawberry*) continue ;; esac
    echo "probe $p:" >&2
    "$p" -MLocale::Maketext -e "print qq(  Locale::Maketext ok\n)" 2>&1 || true
    "$p" -MLocale::Maketext::Simple -e "print qq(  Locale::Maketext::Simple ok\n)" 2>&1 || true
    "$p" -MExtUtils::MakeMaker -e "print qq(  ExtUtils::MakeMaker ok\n)" 2>&1 || true
  done
  exit 1
}

mkdir -p "$PREFIX/lib/pkgconfig" "$PREFIX/include" "$PREFIX/lib" "$PREFIX/bin" "$BUILD_DIR"
export PKG_CONFIG_PATH="$(kotv_native_path "$PREFIX/lib/pkgconfig")${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

if openssl_ver_ok && openssl_has_quic_api \
  && { [[ -f "$PREFIX/lib/libssl.a" || -f "$PREFIX/lib/libssl.dll.a" || -f "$PREFIX/lib/libssl.so" || -f "$PREFIX/lib/libssl.dylib" || -f "$PREFIX/bin/libssl-3-x64.dll" || -f "$PREFIX/bin/libssl-3.dll" ]]; }; then
  echo "ok cached OpenSSL $(pkg-config --modversion openssl 2>/dev/null || pkg-config --modversion libssl) (QUIC)"
  exit 0
fi

# ---------- macOS：brew 仅当带 QUIC API；否则源码编 3.5.x ----------
if ! kotv_is_windows_build && [[ "$(uname -s 2>/dev/null)" == "Darwin" ]] && command -v brew >/dev/null 2>&1; then
  for f in openssl@3.5 openssl@3 openssl; do
    bp="$(brew --prefix "$f" 2>/dev/null || true)"
    [[ -n "$bp" && -d "$bp/lib/pkgconfig" ]] || continue
    export PKG_CONFIG_PATH="$bp/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
    if openssl_ver_ok; then
      ver="$(pkg-config --modversion openssl 2>/dev/null || pkg-config --modversion libssl)"
      for name in openssl libssl libcrypto; do
        [[ -f "$bp/lib/pkgconfig/${name}.pc" ]] || continue
        sed "s|^prefix=.*|prefix=$bp|" "$bp/lib/pkgconfig/${name}.pc" >"$PREFIX/lib/pkgconfig/${name}.pc"
      done
      mkdir -p "$PREFIX/lib" "$PREFIX/include"
      cp -R "$bp/include/openssl" "$PREFIX/include/" 2>/dev/null || true
      shopt -s nullglob
      for lib in "$bp/lib"/libssl* "$bp/lib"/libcrypto*; do
        [[ -e "$lib" ]] || continue
        cp -fR "$lib" "$PREFIX/lib/" 2>/dev/null || true
      done
      shopt -u nullglob
      export PKG_CONFIG_PATH="$(kotv_native_path "$PREFIX/lib/pkgconfig")${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
      if openssl_has_quic_api; then
        echo "ok macOS OpenSSL $ver ← brew $f (QUIC)"
        exit 0
      fi
      echo "WARN: brew $f $ver lacks SSL_set_quic_tls_cbs; will source-build OpenSSL $OPENSSL_VER" >&2
      rm -f "$PREFIX/lib/pkgconfig/openssl.pc" "$PREFIX/lib/pkgconfig/libssl.pc" "$PREFIX/lib/pkgconfig/libcrypto.pc" 2>/dev/null || true
    fi
  done
fi

# ---------- Linux：系统 ≥3.5 且带 QUIC ----------
if ! kotv_is_windows_build && openssl_ver_ok; then
  ver="$(pkg-config --modversion openssl 2>/dev/null || pkg-config --modversion libssl)"
  libs="$(pkg-config --libs openssl 2>/dev/null || pkg-config --libs libssl)"
  cflags="$(pkg-config --cflags openssl 2>/dev/null || pkg-config --cflags libssl || true)"
  cat >"$PREFIX/lib/pkgconfig/openssl.pc" <<EOF
Name: OpenSSL
Description: system OpenSSL mirror
Version: $ver
Libs: $libs
Cflags: $cflags
EOF
  # 把头/库指到系统，便于 openssl_has_quic_api 探测
  if openssl_has_quic_api || { command -v pkg-config >/dev/null && nm -D "$(pkg-config --variable=libdir libssl 2>/dev/null)/libssl.so" 2>/dev/null | grep -q SSL_set_quic_tls_cbs; }; then
    echo "ok system OpenSSL $ver (QUIC)"
    exit 0
  fi
  echo "WARN: system OpenSSL $ver lacks QUIC API; will source-build" >&2
  rm -f "$PREFIX/lib/pkgconfig/openssl.pc"
fi

# ---------- 全平台源码 Configure（含 Windows MinGW + Win7）----------
need() { command -v "$1" >/dev/null || { echo "need $1" >&2; exit 1; }; }
need curl
need tar
need make
if kotv_is_windows_build; then
  kotv_clean_win_path "$BUILD_DIR/bin"
  need gcc
  MAKE="${KOTV_MAKE:-mingw32-make}"
  command -v "$MAKE" >/dev/null || MAKE=make
  ensure_openssl_perl
else
  need perl
  MAKE="${KOTV_MAKE:-make}"
  export PERL="${PERL:-$(command -v perl)}"
fi

src="$BUILD_DIR/openssl-$OPENSSL_VER"
tarball="$BUILD_DIR/openssl-$OPENSSL_VER.tar.gz"
if [[ ! -f "$src/Configure" ]]; then
  curl -fsSL -o "$tarball" \
    "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VER}/openssl-${OPENSSL_VER}.tar.gz"
  rm -rf "$src"
  tar -xzf "$tarball" -C "$BUILD_DIR"
fi

pref="$(kotv_native_path "$PREFIX")"
echo "==> build OpenSSL $OPENSSL_VER → $pref (Configure, perl=$PERL)"
cd "$src"
# 清掉半成品，避免 target 混用
[[ -f Makefile ]] && $MAKE distclean 2>/dev/null || true

cfg_args=(--prefix="$pref" --libdir=lib shared no-docs no-tests enable-quic)
if kotv_is_windows_build; then
  # Win7 宏必须走 CFLAGS，不能当 Configure 位置参数（否则 exit 255）
  export CFLAGS="${WIN7_CFLAGS} ${CFLAGS:-}"
  export CXXFLAGS="${WIN7_CFLAGS} ${CXXFLAGS:-}"
  # mingw64 + QUIC（供 ngtcp2/HTTP3）
  "$PERL" ./Configure mingw64 "${cfg_args[@]}"
else
  "$PERL" ./Configure "${cfg_args[@]}"
fi

$MAKE -j"$JOBS"
$MAKE install_sw

export PKG_CONFIG_PATH="$(kotv_native_path "$PREFIX/lib/pkgconfig")${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
# Windows：把 dll 放到 bin，便于 harvest
if kotv_is_windows_build; then
  shopt -s nullglob
  for dll in "$PREFIX/bin"/libssl*.dll "$PREFIX/bin"/libcrypto*.dll \
             "$PREFIX/lib"/libssl*.dll "$PREFIX/lib"/libcrypto*.dll; do
    [[ -f "$dll" ]] || continue
    cp -f "$dll" "$PREFIX/bin/" 2>/dev/null || true
  done
  shopt -u nullglob
fi
openssl_ver_ok || { echo "ERROR: OpenSSL build unusable" >&2; ls -la "$PREFIX/lib" "$PREFIX/lib/pkgconfig" >&2; exit 1; }
openssl_has_quic_api || { echo "ERROR: OpenSSL built without SSL_set_quic_tls_cbs (HTTP/3)" >&2; exit 1; }
echo "ok OpenSSL $(pkg-config --modversion openssl 2>/dev/null || pkg-config --modversion libssl) (source build, QUIC)"
