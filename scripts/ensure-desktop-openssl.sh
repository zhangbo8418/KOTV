#!/usr/bin/env bash
# 把 OpenSSL（≥3.5，带 QUIC）源码编进 PREFIX，供 ngtcp2/curl HTTP/3。
# Windows：./Configure mingw64 + Win7 宏（不用 MSYS2 预编译包，那些不支持 Win7）。
# macOS：仅当「真实硬件 arch == 目标 arch」且 brew 库内真有 QUIC 符号时用 brew；
#        Rosetta(arch -x86_64) 下 uname 会谎报，禁止误用 arm64 bottle。
# Linux：系统 ≥3.5 且带 QUIC 可用，否则 Configure。
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

# 只认库里的 SSL_set_quic_tls_cbs（头文件声明不足；brew bottle 常无 enable-quic）。
openssl_lib_has_quic() {
  local lib="$1"
  [[ -e "$lib" ]] || return 1
  if nm -gU "$lib" 2>/dev/null | grep -q 'SSL_set_quic_tls_cbs' \
    || nm -D "$lib" 2>/dev/null | grep -q 'SSL_set_quic_tls_cbs' \
    || strings "$lib" 2>/dev/null | grep -q 'SSL_set_quic_tls_cbs'; then
    return 0
  fi
  return 1
}

openssl_has_quic_api() {
  local lib
  for lib in \
    "$PREFIX/lib/libssl.dylib" "$PREFIX/lib/libssl.so" "$PREFIX/lib/libssl.so.3" \
    "$PREFIX/lib/libssl.dll.a" "$PREFIX/bin/libssl-3-x64.dll" "$PREFIX/bin/libssl-3.dll" \
    "$PREFIX/lib/libssl-3.dll"; do
    openssl_lib_has_quic "$lib" && return 0
  done
  return 1
}

kotv_macos_can_use_brew_openssl() {
  [[ "$(uname -s 2>/dev/null)" == "Darwin" ]] || return 1
  local hw want
  hw="$(kotv_macos_hw_arch)"
  want="$(kotv_macos_target_arch)"
  # Rosetta：hw=arm64 但 uname/目标为 x86_64 → 绝不能用 /opt/homebrew arm64 bottle
  [[ -n "$hw" && -n "$want" && "$hw" == "$want" ]]
}

kotv_clear_prefix_openssl() {
  rm -f "$PREFIX/lib/pkgconfig/openssl.pc" "$PREFIX/lib/pkgconfig/libssl.pc" "$PREFIX/lib/pkgconfig/libcrypto.pc" 2>/dev/null || true
  rm -f "$PREFIX/lib"/libssl* "$PREFIX/lib"/libcrypto* 2>/dev/null || true
  rm -rf "$PREFIX/include/openssl" 2>/dev/null || true
}

# OpenSSL Configure/make：MSYS/Git perl + 本地纯 Perl vendor（禁止 Strawberry 整库 PERL5LIB 污染 Config.pm）。
# 静态链（Configure）：OpenSSL::config → IPC::Cmd → Params::Check → Locale::Maketext::Simple
#                      Locale::Maketext → I18N::LangTags；Makefile → ExtUtils::MakeMaker
# 静态链（make）：configdata.pm → Pod::Usage → Pod::Text(podlators) → Pod::Simple
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
  found="$(find "$tmp" -maxdepth 1 -mindepth 1 -type d \( -name "${dist}-*" -o -name "${dist}-v*" \) | head -1 || true)"
  [[ -n "$found" && -d "$found/lib" ]] || return 1
  cp -R "$found/lib/." "$local_lib/"
  rm -rf "$tmp"
  return 0
}

kotv_copy_strawberry_pm() {
  local local_lib="$1" rel="$2"
  local src
  for src in /c/Strawberry/perl/lib /c/strawberry/perl/lib \
             /c/Strawberry/perl/vendor/lib /c/strawberry/perl/vendor/lib \
             /c/Strawberry/perl/site/lib /c/strawberry/perl/site/lib; do
    if [[ -f "$src/$rel" ]]; then
      mkdir -p "$local_lib/$(dirname "$rel")"
      cp -f "$src/$rel" "$local_lib/$rel"
      return 0
    fi
    if [[ -d "$src/$rel" ]]; then
      mkdir -p "$local_lib/$rel"
      cp -R "$src/$rel/." "$local_lib/$rel/"
      return 0
    fi
  done
  return 1
}

# 一次性从 Strawberry 拷纯 Perl 目录（严禁拷 File/Encode 等带 XS 的模块：
# 否则会出现 File::Glob object version 1.42 does not match … 1.33）。
kotv_vendor_strawberry_pureperl_trees() {
  local local_lib="$1" d
  for d in Pod Locale I18N ExtUtils Module Params Text Getopt HTTP; do
    kotv_copy_strawberry_pm "$local_lib" "$d" || true
  done
  # 清掉误拷的 XS 包装，强制用 Git perl 自带的 File::Glob 等
  rm -rf "$local_lib/File" "$local_lib/Encode" "$local_lib/Carp" \
    "$local_lib/IPC" "$local_lib/AutoLoader" "$local_lib/DynaLoader.pm" 2>/dev/null || true
}

# 从 "Can't locate Foo/Bar.pm" 错误里 vendor 缺失模块。
kotv_vendor_cant_locate() {
  local err="$1" mod dest
  mod="$(printf '%s\n' "$err" | sed -n 's/.*Can'\''t locate \([^ ]*\) in @INC.*/\1/p' | head -1)"
  [[ -n "$mod" ]] || return 1
  # 禁止 vendor XS 核心模块（会与 Git perl .so 版本冲突）
  case "$mod" in
    File/*|Encode*|Carp*|IPC/*|DynaLoader*|XSLoader*|Config*)
      echo "ERROR: refusing to vendor XS/core module $mod into PERL5LIB" >&2
      return 1
      ;;
  esac
  echo "WARN: perl missing $mod; vendoring" >&2
  if kotv_copy_strawberry_pm "$BUILD_DIR/perl5" "$mod"; then
    return 0
  fi
  dest="$(dirname "$mod")"
  if [[ "$dest" != "." ]] && kotv_copy_strawberry_pm "$BUILD_DIR/perl5" "$dest"; then
    return 0
  fi
  return 1
}

ensure_openssl_perl() {
  local p candidates=() local_lib="$BUILD_DIR/perl5"
  mkdir -p "$local_lib"
  if kotv_is_windows_build; then
    candidates+=(/usr/bin/perl /bin/perl)
    unset PERL5LIB || true
  fi
  candidates+=("$(command -v perl 2>/dev/null || true)")

  # CPAN：Configure + make(configdata→Pod::Usage) 全链一次到位
  kotv_vendor_cpan_lib "$local_lib" Locale-Maketext \
    "https://cpan.metacpan.org/authors/id/T/TO/TODDR/Locale-Maketext-1.33.tar.gz" \
    "Locale/Maketext.pm" || true
  kotv_vendor_cpan_lib "$local_lib" Locale-Maketext-Simple \
    "https://cpan.metacpan.org/authors/id/J/JE/JESSE/Locale-Maketext-Simple-0.21.tar.gz" \
    "Locale/Maketext/Simple.pm" || true
  kotv_vendor_cpan_lib "$local_lib" I18N-LangTags \
    "https://cpan.metacpan.org/authors/id/S/SB/SBURKE/I18N-LangTags-0.35.tar.gz" \
    "I18N/LangTags.pm" || true
  kotv_vendor_cpan_lib "$local_lib" ExtUtils-MakeMaker \
    "https://cpan.metacpan.org/authors/id/B/BI/BINGOS/ExtUtils-MakeMaker-7.70.tar.gz" \
    "ExtUtils/MakeMaker.pm" || true
  kotv_vendor_cpan_lib "$local_lib" Params-Check \
    "https://cpan.metacpan.org/authors/id/B/BI/BINGOS/Params-Check-0.38.tar.gz" \
    "Params/Check.pm" || true
  kotv_vendor_cpan_lib "$local_lib" Module-Load \
    "https://cpan.metacpan.org/authors/id/B/BI/BINGOS/Module-Load-0.36.tar.gz" \
    "Module/Load.pm" || true
  kotv_vendor_cpan_lib "$local_lib" Module-Load-Conditional \
    "https://cpan.metacpan.org/authors/id/B/BI/BINGOS/Module-Load-Conditional-0.74.tar.gz" \
    "Module/Load/Conditional.pm" || true
  kotv_vendor_cpan_lib "$local_lib" Pod-Simple \
    "https://cpan.metacpan.org/authors/id/K/KH/KHW/Pod-Simple-3.48.tar.gz" \
    "Pod/Simple.pm" || true
  kotv_vendor_cpan_lib "$local_lib" podlators \
    "https://cpan.metacpan.org/authors/id/R/RR/RRA/podlators-v6.1.0.tar.gz" \
    "Pod/Text.pm" || true
  kotv_vendor_cpan_lib "$local_lib" Pod-Usage \
    "https://cpan.metacpan.org/authors/id/M/MA/MAREKR/Pod-Usage-2.05.tar.gz" \
    "Pod/Usage.pm" || true

  if kotv_is_windows_build; then
    kotv_vendor_strawberry_pureperl_trees "$local_lib"
  fi
  # 无论从哪拷的，都清掉会撞 XS 的 File::Glob 等
  rm -rf "$local_lib/File" "$local_lib/Encode" "$local_lib/Carp" \
    "$local_lib/IPC" "$local_lib/AutoLoader" "$local_lib/DynaLoader.pm" 2>/dev/null || true
  export PERL5LIB="$local_lib"

  for p in "${candidates[@]}"; do
    [[ -n "$p" && -x "$p" ]] || continue
    case "$p" in *[Ss]trawberry*) continue ;; esac
    if "$p" -MLocale::Maketext -e "1" 2>/dev/null \
      && "$p" -MI18N::LangTags -e "1" 2>/dev/null \
      && "$p" -MLocale::Maketext::Simple -e "1" 2>/dev/null \
      && "$p" -MExtUtils::MakeMaker -e "1" 2>/dev/null \
      && "$p" -MIPC::Cmd -e "1" 2>/dev/null \
      && "$p" -MPod::Usage -e "1" 2>/dev/null; then
      export PERL="$p"
      echo "ok perl for OpenSSL: $PERL (PERL5LIB=$PERL5LIB)"
      return 0
    fi
  done
  echo "ERROR: need MSYS/Git perl + Configure/make perl module chain" >&2
  ls -laR "$local_lib" 2>/dev/null | head -120 >&2 || true
  for p in "${candidates[@]}"; do
    [[ -n "$p" && -x "$p" ]] || continue
    case "$p" in *[Ss]trawberry*) continue ;; esac
    echo "probe $p:" >&2
    for m in Locale::Maketext I18N::LangTags Locale::Maketext::Simple ExtUtils::MakeMaker IPC::Cmd Pod::Usage Pod::Text Pod::Simple; do
      "$p" -M"$m" -e "print qq(  $m ok\n)" 2>&1 || true
    done
  done
  exit 1
}

# Configure 前探 OpenSSL::config；缺模块自动补。
ensure_openssl_perl_can_configure() {
  local src="$1" i=0 err
  [[ -n "${PERL:-}" && -f "$src/util/perl/OpenSSL/config.pm" ]] || return 0
  export PERL5LIB="${BUILD_DIR}/perl5${PERL5LIB:+:$PERL5LIB}"
  while [[ "$i" -lt 25 ]]; do
    i=$((i + 1))
    if "$PERL" -I"$src/util/perl" -I"$src/external/perl/Text-Template-1.56/lib" \
      -MOpenSSL::config -e "1" 2>/dev/null; then
      echo "ok perl OpenSSL::config probe"
      return 0
    fi
    err="$("$PERL" -I"$src/util/perl" -I"$src/external/perl/Text-Template-1.56/lib" \
      -MOpenSSL::config -e "1" 2>&1 || true)"
    if kotv_vendor_cant_locate "$err"; then
      continue
    fi
    echo "ERROR: OpenSSL::config probe failed:" >&2
    printf '%s\n' "$err" >&2
    return 1
  done
  echo "ERROR: too many missing perl modules for OpenSSL::config" >&2
  return 1
}

# Configure 后探 configdata.pm（make 会用到 Pod::Usage）。
ensure_openssl_perl_can_make() {
  local src="$1" i=0 err
  [[ -n "${PERL:-}" && -f "$src/configdata.pm" ]] || return 0
  export PERL5LIB="${BUILD_DIR}/perl5${PERL5LIB:+:$PERL5LIB}"
  cd "$src"
  while [[ "$i" -lt 25 ]]; do
    i=$((i + 1))
    if "$PERL" -e 'do "./configdata.pm" or die $@; 1' 2>/dev/null; then
      echo "ok perl configdata.pm probe"
      return 0
    fi
    err="$("$PERL" -e 'do "./configdata.pm" or die $@; 1' 2>&1 || true)"
    if kotv_vendor_cant_locate "$err"; then
      continue
    fi
    echo "ERROR: configdata.pm probe failed:" >&2
    printf '%s\n' "$err" >&2
    return 1
  done
  echo "ERROR: too many missing perl modules for configdata.pm" >&2
  return 1
}

# make：若仍报 Can't locate，补模块后重试（最多 10 次）。
kotv_openssl_make() {
  local log="$BUILD_DIR/openssl-make.log" i=0
  export PERL5LIB="${BUILD_DIR}/perl5${PERL5LIB:+:$PERL5LIB}"
  while [[ "$i" -lt 10 ]]; do
    i=$((i + 1))
    if $MAKE -j"$JOBS" 2>"$log"; then
      cat "$log" 2>/dev/null || true
      return 0
    fi
    cat "$log" >&2 || true
    if rg -q "Can't locate " "$log" 2>/dev/null || grep -q "Can't locate " "$log" 2>/dev/null; then
      if kotv_vendor_cant_locate "$(cat "$log")"; then
        echo "WARN: openssl make missing perl module; retry $i" >&2
        continue
      fi
    fi
    return 1
  done
  return 1
}


mkdir -p "$PREFIX/lib/pkgconfig" "$PREFIX/include" "$PREFIX/lib" "$PREFIX/bin" "$BUILD_DIR"
export PKG_CONFIG_PATH="$(kotv_native_path "$PREFIX/lib/pkgconfig")${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

# 缓存：须带 QUIC；macOS 还须 arch 匹配目标（避免 Rosetta 任务吃到 arm64 缓存）
if openssl_ver_ok && openssl_has_quic_api \
  && { [[ -f "$PREFIX/lib/libssl.a" || -f "$PREFIX/lib/libssl.dll.a" || -f "$PREFIX/lib/libssl.so" || -f "$PREFIX/lib/libssl.dylib" || -f "$PREFIX/bin/libssl-3-x64.dll" || -f "$PREFIX/bin/libssl-3.dll" ]]; }; then
  if [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
    if ! kotv_macos_file_has_arch "$PREFIX/lib/libssl.dylib" "$(kotv_macos_target_arch)"; then
      echo "WARN: cached OpenSSL arch mismatch for $(kotv_macos_target_arch); rebuild" >&2
      kotv_clear_prefix_openssl
    else
      echo "ok cached OpenSSL $(pkg-config --modversion openssl 2>/dev/null || pkg-config --modversion libssl) (QUIC)"
      exit 0
    fi
  else
    echo "ok cached OpenSSL $(pkg-config --modversion openssl 2>/dev/null || pkg-config --modversion libssl) (QUIC)"
    exit 0
  fi
fi

# ---------- macOS brew（同硬件 arch + 库内 QUIC）----------
if ! kotv_is_windows_build && kotv_macos_can_use_brew_openssl && command -v brew >/dev/null 2>&1; then
  for f in openssl@3.5 openssl@3 openssl; do
    bp="$(brew --prefix "$f" 2>/dev/null || true)"
    [[ -n "$bp" && -d "$bp/lib/pkgconfig" ]] || continue
    brew_ssl=""
    for cand in "$bp/lib/libssl.dylib" "$bp/lib/libssl.3.dylib"; do
      [[ -f "$cand" ]] && brew_ssl="$cand" && break
    done
    [[ -n "$brew_ssl" ]] || continue
    if ! kotv_macos_file_has_arch "$brew_ssl" "$(kotv_macos_target_arch)"; then
      echo "WARN: brew $f libssl arch != $(kotv_macos_target_arch); skip" >&2
      continue
    fi
    if ! openssl_lib_has_quic "$brew_ssl"; then
      echo "WARN: brew $f lacks SSL_set_quic_tls_cbs in dylib; skip" >&2
      continue
    fi
    export PKG_CONFIG_PATH="$bp/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
    if ! openssl_ver_ok; then
      continue
    fi
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
    kotv_clear_prefix_openssl
  done
elif ! kotv_is_windows_build && [[ "$(uname -s 2>/dev/null)" == "Darwin" ]] && ! kotv_macos_can_use_brew_openssl; then
  echo "WARN: macOS hw=$(kotv_macos_hw_arch) target=$(kotv_macos_target_arch); skip brew, source-build" >&2
  kotv_clear_prefix_openssl
fi

# ---------- Linux：系统 ≥3.5 且带 QUIC（勿在 Darwin 误走）----------
if ! kotv_is_windows_build && [[ "$(uname -s 2>/dev/null)" == "Linux" ]] && openssl_ver_ok; then
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
  sys_lib="$(pkg-config --variable=libdir libssl 2>/dev/null || true)/libssl.so"
  if openssl_has_quic_api || openssl_lib_has_quic "$sys_lib"; then
    echo "ok system OpenSSL $ver (QUIC)"
    exit 0
  fi
  echo "WARN: system OpenSSL $ver lacks QUIC API; will source-build" >&2
  rm -f "$PREFIX/lib/pkgconfig/openssl.pc"
fi

# ---------- 全平台源码 Configure ----------
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

if kotv_is_windows_build; then
  ensure_openssl_perl_can_configure "$src" || exit 1
fi

pref="$(kotv_native_path "$PREFIX")"
echo "==> build OpenSSL $OPENSSL_VER → $pref (Configure, perl=$PERL)"
cd "$src"
[[ -f Makefile ]] && $MAKE distclean 2>/dev/null || true

cfg_args=(--prefix="$pref" --libdir=lib shared no-docs no-tests enable-quic)
if kotv_is_windows_build; then
  export CFLAGS="${WIN7_CFLAGS} ${CFLAGS:-}"
  export CXXFLAGS="${WIN7_CFLAGS} ${CXXFLAGS:-}"
  "$PERL" ./Configure mingw64 "${cfg_args[@]}"
elif [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
  local_arch="$(kotv_macos_target_arch)"
  export CFLAGS="-arch ${local_arch} ${CFLAGS:-}"
  export CXXFLAGS="-arch ${local_arch} ${CXXFLAGS:-}"
  export LDFLAGS="-arch ${local_arch} ${LDFLAGS:-}"
  case "$local_arch" in
    x86_64) "$PERL" ./Configure darwin64-x86_64-cc "${cfg_args[@]}" ;;
    arm64|aarch64) "$PERL" ./Configure darwin64-arm64-cc "${cfg_args[@]}" ;;
    *) "$PERL" ./Configure "${cfg_args[@]}" ;;
  esac
else
  "$PERL" ./Configure "${cfg_args[@]}"
fi

if kotv_is_windows_build; then
  ensure_openssl_perl_can_make "$src" || exit 1
  kotv_openssl_make || exit 1
else
  $MAKE -j"$JOBS"
fi
$MAKE install_sw

export PKG_CONFIG_PATH="$(kotv_native_path "$PREFIX/lib/pkgconfig")${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
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
if [[ "$(uname -s 2>/dev/null)" == "Darwin" ]] && ! kotv_macos_file_has_arch "$PREFIX/lib/libssl.dylib" "$(kotv_macos_target_arch)"; then
  echo "ERROR: OpenSSL dylib arch != $(kotv_macos_target_arch)" >&2
  lipo -info "$PREFIX/lib/libssl.dylib" >&2 || true
  exit 1
fi
echo "ok OpenSSL $(pkg-config --modversion openssl 2>/dev/null || pkg-config --modversion libssl) (source build, QUIC)"
