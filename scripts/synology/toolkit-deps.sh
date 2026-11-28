#!/usr/bin/env bash
# Toolkit 工具链自编运行时外部库 → .syno-deps/<platform>/
# 由 build-runtime-in-chroot.sh source（需 download、PLATFORM、CC、SYSROOT、SRC_CACHE、BUILD_ROOT、ROOT）。
#
# 原则：目标链接只用此前缀 + Toolkit sysroot libc，绝不用宿主 /usr。
# 各 profile 在组件 configure 前按 DAG 一次编齐（含传递依赖）。
# shellcheck shell=bash

kotv_syno_deps_prefix() {
  echo "${KOTV_SYNO_DEPS_PREFIX:-${ROOT:?}/.syno-deps/${PLATFORM:?}}"
}

kotv_syno_deps_host_triple() {
  case "${PLATFORM:?}" in
    geminilake) echo "x86_64-pc-linux-gnu" ;;
    rtd1296)    echo "aarch64-unknown-linux-gnu" ;;
    *) echo "ERROR: unknown PLATFORM=$PLATFORM" >&2; return 1 ;;
  esac
}

kotv_syno_export_deps_env() {
  local deps
  deps="$(kotv_syno_deps_prefix)"
  export PKG_CONFIG_SYSROOT_DIR=""
  export PKG_CONFIG_LIBDIR="${deps}/lib/pkgconfig:${deps}/lib64/pkgconfig:${deps}/share/pkgconfig"
  export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"
  case " ${CPPFLAGS:-} " in
    *" -I${deps}/include "*) ;;
    *) export CPPFLAGS="-I${deps}/include ${CPPFLAGS:-}" ;;
  esac
  case " ${LDFLAGS:-} " in
    *" -L${deps}/lib "*) ;;
    *) export LDFLAGS="-L${deps}/lib -L${deps}/lib64 -Wl,-rpath-link,${deps}/lib -Wl,-rpath-link,${deps}/lib64 ${LDFLAGS:-}" ;;
  esac
}

kotv_syno_deps_ship_shared() {
  local dest_lib="$1"
  shift
  local deps name
  deps="$(kotv_syno_deps_prefix)"
  mkdir -p "$dest_lib"
  for name in "$@"; do
    # 只拷真实存在的 .so（静态库静默跳过）
    shopt -s nullglob
    local files=( "${deps}/lib/lib${name}.so"* "${deps}/lib64/lib${name}.so"* )
    shopt -u nullglob
    ((${#files[@]})) && cp -a "${files[@]}" "$dest_lib/" || true
  done
}

# ---------- stamp / 解压 / autotools ----------

kotv_syno_dep_ok() {
  local name="$1" ver="$2" probe="$3" deps stamp
  deps="$(kotv_syno_deps_prefix)"
  stamp="$deps/.kotv-dep-${name}"
  [[ -f "$stamp" && "$(cat "$stamp" 2>/dev/null || true)" == "$ver" && -e "$deps/$probe" ]]
}

kotv_syno_dep_mark() {
  local name="$1" ver="$2" deps
  deps="$(kotv_syno_deps_prefix)"
  mkdir -p "$deps"
  echo "$ver" >"$deps/.kotv-dep-${name}"
  echo "[deps] $name $ver → $deps"
}

kotv_syno_dep_fetch() {
  # $1=url → 打印本地 tarball 路径；坏包删除重下
  local url="$1" tarball
  tarball="$SRC_CACHE/$(basename "${url%%\?*}")"
  # github archive 常同名；用 URL 末段即可
  if [[ "$url" == *"/archive/refs/tags/"* ]]; then
    local tag ver name
    tag="$(basename "$url")"          # v1.1.0.tar.gz
    name="$(echo "$url" | sed -n 's|.*/\([^/]*\)/archive/.*|\1|p')"
    tarball="$SRC_CACHE/${name}-${tag#v}"
  fi
  download "$url" "$tarball" || return 1
  if [[ "$tarball" == *.gz || "$tarball" == *.tgz ]]; then
    if ! gzip -t "$tarball" 2>/dev/null; then
      echo "[deps] corrupt archive, re-download: $(basename "$tarball")" >&2
      rm -f "$tarball"
      download "$url" "$tarball" || return 1
      gzip -t "$tarball" || { echo "ERROR: bad gzip: $tarball" >&2; return 1; }
    fi
  fi
  # 仅路径走 stdout（供 tarball="$(kotv_syno_dep_fetch …)"）
  printf '%s\n' "$tarball"
}

kotv_syno_dep_extract() {
  local tarball="$1" dirname="$2" src
  src="$BUILD_ROOT/$dirname"
  rm -rf "$src"
  mkdir -p "$BUILD_ROOT"
  case "$tarball" in
    *.tar.gz|*.tgz) tar -xzf "$tarball" -C "$BUILD_ROOT" || return 1 ;;
    *.tar.xz)       tar -xJf "$tarball" -C "$BUILD_ROOT" || return 1 ;;
    *.tar.bz2)      tar -xjf "$tarball" -C "$BUILD_ROOT" || return 1 ;;
    *) echo "ERROR: unknown archive: $tarball" >&2; return 1 ;;
  esac
  # github archive: brotli-1.1.0
  if [[ ! -d "$src" ]]; then
    echo "ERROR: extract missing dir $src (from $(basename "$tarball"))" >&2
    ls -la "$BUILD_ROOT" | head -20 >&2 || true
    return 1
  fi
  echo "$src"
}

kotv_syno_dep_autotools() {
  local name="$1" ver="$2" url="$3" dirname="$4" probe="$5"
  shift 5
  local deps host jobs tarball src
  if kotv_syno_dep_ok "$name" "$ver" "$probe"; then
    echo "[deps] $name $ver cache hit"
    return 0
  fi
  deps="$(kotv_syno_deps_prefix)"
  host="$(kotv_syno_deps_host_triple)"
  jobs="$(kotv_syno_njobs)"
  tarball="$(kotv_syno_dep_fetch "$url")"
  src="$(kotv_syno_dep_extract "$tarball" "$dirname")"
  mkdir -p "$deps"
  (
    cd "$src"
    ./configure \
      --prefix="$deps" \
      --host="$host" \
      "$@" \
      CC="$CC" CXX="$CXX" \
      CFLAGS="$CFLAGS" CXXFLAGS="$CXXFLAGS" LDFLAGS="$LDFLAGS" \
      CPPFLAGS="${CPPFLAGS:-}" \
      PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-}" \
      PKG_CONFIG_SYSROOT_DIR="${PKG_CONFIG_SYSROOT_DIR:-}"
    make -j"$jobs"
    make install
  )
  kotv_syno_dep_mark "$name" "$ver"
}

# ---------- 单库 ----------

kotv_syno_dep_zlib() {
  kotv_syno_load_versions
  local ver="$SYNO_ZLIB_VER" deps host jobs tarball src
  if kotv_syno_dep_ok zlib "$ver" "include/zlib.h"; then
    echo "[deps] zlib $ver cache hit"; return 0
  fi
  deps="$(kotv_syno_deps_prefix)"; host="$(kotv_syno_deps_host_triple)"; jobs="$(kotv_syno_njobs)"
  tarball="$(kotv_syno_dep_fetch "https://github.com/madler/zlib/releases/download/v${ver}/zlib-${ver}.tar.gz")"
  src="$(kotv_syno_dep_extract "$tarball" "zlib-${ver}")"
  mkdir -p "$deps"
  (
    cd "$src"
    CHOST="$host" ./configure --prefix="$deps"
    make -j"$jobs" CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS"
    make install
  )
  kotv_syno_dep_mark zlib "$ver"
}

kotv_syno_dep_bzip2() {
  kotv_syno_load_versions
  local ver="$SYNO_BZIP2_VER" deps jobs tarball src
  if kotv_syno_dep_ok bzip2 "$ver" "include/bzlib.h"; then
    echo "[deps] bzip2 $ver cache hit"; return 0
  fi
  deps="$(kotv_syno_deps_prefix)"; jobs="$(kotv_syno_njobs)"
  tarball="$(kotv_syno_dep_fetch "https://sourceware.org/pub/bzip2/bzip2-${ver}.tar.gz")"
  src="$(kotv_syno_dep_extract "$tarball" "bzip2-${ver}")"
  mkdir -p "$deps/lib" "$deps/include"
  (
    cd "$src"
    make -j"$jobs" CC="$CC" AR="$AR" RANLIB="$RANLIB" \
      CFLAGS="$CFLAGS -fPIC" LDFLAGS="$LDFLAGS" -f Makefile-libbz2_so
    make CC="$CC" AR="$AR" RANLIB="$RANLIB" CFLAGS="$CFLAGS -fPIC" libbz2.a
    cp -a bzlib.h "$deps/include/"
    cp -a libbz2.a "$deps/lib/"
    cp -a "libbz2.so.${ver}" "$deps/lib/" 2>/dev/null || true
    ln -sfn "libbz2.so.${ver}" "$deps/lib/libbz2.so.1.0" 2>/dev/null || true
    ln -sfn "libbz2.so.${ver}" "$deps/lib/libbz2.so" 2>/dev/null || true
  )
  kotv_syno_dep_mark bzip2 "$ver"
}

# 只装静态库：避免 sysroot LDFLAGS 下 shared 链 Scrt1 → undefined main
kotv_syno_dep_zstd() {
  kotv_syno_load_versions
  local ver="$SYNO_ZSTD_VER" deps jobs tarball src
  if kotv_syno_dep_ok zstd "${ver}-pic" "include/zdict.h"; then
    echo "[deps] zstd $ver cache hit"; return 0
  fi
  deps="$(kotv_syno_deps_prefix)"; jobs="$(kotv_syno_njobs)"
  tarball="$(kotv_syno_dep_fetch "https://github.com/facebook/zstd/releases/download/v${ver}/zstd-${ver}.tar.gz")"
  src="$(kotv_syno_dep_extract "$tarball" "zstd-${ver}")"
  mkdir -p "$deps/lib" "$deps/include" "$deps/lib/pkgconfig"
  (
    cd "$src"
    # CPython 把 libzstd.a 链进 _zstd.so，必须 -fPIC
    make -j"$jobs" -C lib CC="$CC" AR="$AR" \
      CFLAGS="$CFLAGS -fPIC" LDFLAGS="$LDFLAGS" libzstd.a
    cp -a lib/libzstd.a "$deps/lib/"
    # CPython _zstd 还要 zdict.h
    cp -a lib/zstd.h lib/zstd_errors.h lib/zdict.h "$deps/include/" 2>/dev/null \
      || cp -a lib/*.h "$deps/include/"
    cat >"$deps/lib/pkgconfig/libzstd.pc" <<EOF
prefix=$deps
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: zstd
Description: Zstd static
Version: $ver
Libs: -L\${libdir} -lzstd
Cflags: -I\${includedir}
EOF
  )
  # stamp 带 -pic：逼旧 cache（无 -fPIC 的 .a）失效
  kotv_syno_dep_mark zstd "${ver}-pic"
}

kotv_syno_dep_openssl() {
  kotv_syno_load_versions
  local ver="$SYNO_OPENSSL_VER" deps jobs tarball src target
  if kotv_syno_dep_ok openssl "$ver" "include/openssl/ssl.h"; then
    echo "[deps] openssl $ver cache hit"; return 0
  fi
  deps="$(kotv_syno_deps_prefix)"; jobs="$(kotv_syno_njobs)"
  case "$PLATFORM" in
    geminilake) target="linux-x86_64" ;;
    rtd1296)    target="linux-aarch64" ;;
  esac
  tarball="$(kotv_syno_dep_fetch "https://github.com/openssl/openssl/releases/download/openssl-${ver}/openssl-${ver}.tar.gz")"
  src="$(kotv_syno_dep_extract "$tarball" "openssl-${ver}")"
  mkdir -p "$deps"
  (
    cd "$src"
    ./Configure "$target" \
      --prefix="$deps" --openssldir="$deps/ssl" \
      --libdir=lib \
      shared no-tests no-docs \
      "CC=$CC" "CXX=$CXX" "CFLAGS=$CFLAGS" "LDFLAGS=$LDFLAGS"
    make -j"$jobs"
    make install_sw
  )
  kotv_syno_dep_mark openssl "$ver"
}

kotv_syno_dep_brotli() {
  kotv_syno_load_versions
  local ver="$SYNO_BROTLI_VER" deps jobs tarball src
  if kotv_syno_dep_ok brotli "$ver" "include/brotli/decode.h"; then
    echo "[deps] brotli $ver cache hit"; return 0
  fi
  deps="$(kotv_syno_deps_prefix)"; jobs="$(kotv_syno_njobs)"
  tarball="$(kotv_syno_dep_fetch "https://github.com/google/brotli/archive/refs/tags/v${ver}.tar.gz")"
  # archive 解出 brotli-1.1.0
  src="$(kotv_syno_dep_extract "$tarball" "brotli-${ver}")"
  mkdir -p "$deps"
  local cmake_x=()
  if [[ "$PLATFORM" == rtd1296 ]]; then
    cmake_x=(-DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=aarch64)
  fi
  (
    cd "$src"
    mkdir -p out && cd out
    cmake .. \
      "${cmake_x[@]}" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="$deps" \
      -DCMAKE_C_COMPILER="$CC" \
      -DCMAKE_CXX_COMPILER="$CXX" \
      -DCMAKE_C_FLAGS="$CFLAGS" \
      -DCMAKE_CXX_FLAGS="$CXXFLAGS" \
      -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS" \
      -DCMAKE_SHARED_LINKER_FLAGS="$LDFLAGS" \
      -DBUILD_SHARED_LIBS=ON
    make -j"$jobs"
    make install
  )
  kotv_syno_dep_mark brotli "$ver"
}

kotv_syno_dep_cups() {
  kotv_syno_load_versions
  local ver="$SYNO_CUPS_VER" deps host jobs tarball src
  if kotv_syno_dep_ok cups "$ver" "include/cups/cups.h"; then
    echo "[deps] cups $ver cache hit"; return 0
  fi
  deps="$(kotv_syno_deps_prefix)"; host="$(kotv_syno_deps_host_triple)"; jobs="$(kotv_syno_njobs)"
  tarball="$(kotv_syno_dep_fetch "https://github.com/OpenPrinting/cups/releases/download/v${ver}/cups-${ver}-source.tar.gz")"
  src="$(kotv_syno_dep_extract "$tarball" "cups-${ver}")"
  mkdir -p "$deps"
  (
    cd "$src"
    # --with-rcdir=no：不装 /etc/rc*.d
    ./configure \
      --prefix="$deps" \
      --host="$host" \
      --disable-libusb --disable-dbus --disable-pam --disable-gssapi \
      --disable-systemd --with-tls=no --disable-browsing \
      --with-rcdir=no \
      CC="$CC" CXX="$CXX" \
      CFLAGS="$CFLAGS" CXXFLAGS="$CXXFLAGS" LDFLAGS="$LDFLAGS" \
      CPPFLAGS="${CPPFLAGS:-}"
    make -j"$jobs"
    make install
  )
  kotv_syno_dep_mark cups "$ver"
}

# ---------- profiles ----------

kotv_syno_ensure_deps_node() {
  kotv_syno_load_versions
  # brotli 用 Node 树内（与源码常量对齐）；其余 Toolkit overlay
  echo "[deps] profile=node (zlib c-ares nghttp2 openssl)"
  kotv_syno_dep_zlib
  kotv_syno_export_deps_env
  kotv_syno_dep_autotools cares "$SYNO_CARES_VER" \
    "https://github.com/c-ares/c-ares/releases/download/v${SYNO_CARES_VER}/c-ares-${SYNO_CARES_VER}.tar.gz" \
    "c-ares-${SYNO_CARES_VER}" "include/ares.h" \
    --disable-tests
  kotv_syno_dep_autotools nghttp2 "$SYNO_NGHTTP2_VER" \
    "https://github.com/nghttp2/nghttp2/releases/download/v${SYNO_NGHTTP2_VER}/nghttp2-${SYNO_NGHTTP2_VER}.tar.gz" \
    "nghttp2-${SYNO_NGHTTP2_VER}" "include/nghttp2/nghttp2.h" \
    --enable-lib-only --disable-examples --disable-python-bindings
  kotv_syno_dep_openssl
  kotv_syno_export_deps_env
}

kotv_syno_ensure_deps_python() {
  kotv_syno_load_versions
  echo "[deps] profile=python (CPython optional modules)"
  kotv_syno_dep_zlib
  kotv_syno_export_deps_env
  kotv_syno_dep_bzip2
  kotv_syno_dep_autotools xz "$SYNO_XZ_VER" \
    "https://github.com/tukaani-project/xz/releases/download/v${SYNO_XZ_VER}/xz-${SYNO_XZ_VER}.tar.gz" \
    "xz-${SYNO_XZ_VER}" "include/lzma.h" \
    --disable-doc --disable-scripts --disable-xzdec --disable-lzmadec \
    --enable-static --disable-shared
  kotv_syno_dep_zstd
  kotv_syno_dep_autotools libffi "$SYNO_LIBFFI_VER" \
    "https://github.com/libffi/libffi/releases/download/v${SYNO_LIBFFI_VER}/libffi-${SYNO_LIBFFI_VER}.tar.gz" \
    "libffi-${SYNO_LIBFFI_VER}" "include/ffi.h" \
    --disable-docs --disable-multi-os-directory --enable-static --disable-shared
  kotv_syno_dep_openssl
  kotv_syno_export_deps_env
  kotv_syno_dep_autotools sqlite "$SYNO_SQLITE_VER" \
    "https://www.sqlite.org/${SYNO_SQLITE_YEAR}/sqlite-autoconf-${SYNO_SQLITE_VER}.tar.gz" \
    "sqlite-autoconf-${SYNO_SQLITE_VER}" "include/sqlite3.h" \
    --enable-threadsafe
  # --without-progs：交叉时 host strip 无法剥目标 tic 等；stamp 带 -noprogs 迫使旧缓存重建
  kotv_syno_dep_autotools ncurses "${SYNO_NCURSES_VER}-noprogs" \
    "https://ftp.gnu.org/gnu/ncurses/ncurses-${SYNO_NCURSES_VER}.tar.gz" \
    "ncurses-${SYNO_NCURSES_VER}" "include/ncursesw/curses.h" \
    --with-shared --without-debug --without-ada --enable-widec \
    --without-progs --without-tests --without-manpages \
    --enable-pc-files --with-pkg-config-libdir="$(kotv_syno_deps_prefix)/lib/pkgconfig"
  local deps; deps="$(kotv_syno_deps_prefix)"
  mkdir -p "$deps/include"
  if [[ -d "$deps/include/ncursesw" ]]; then
    [[ -e "$deps/include/ncurses" ]] || ln -sfn ncursesw "$deps/include/ncurses"
    [[ -e "$deps/include/curses.h" ]] || ln -sfn ncursesw/curses.h "$deps/include/curses.h"
  fi
  kotv_syno_export_deps_env
  kotv_syno_dep_autotools readline "$SYNO_READLINE_VER" \
    "https://ftp.gnu.org/gnu/readline/readline-${SYNO_READLINE_VER}.tar.gz" \
    "readline-${SYNO_READLINE_VER}" "include/readline/readline.h" \
    --with-curses --disable-shared --enable-static
  kotv_syno_dep_autotools util-linux "$SYNO_UTIL_LINUX_VER" \
    "https://www.kernel.org/pub/linux/utils/util-linux/v${SYNO_UTIL_LINUX_VER%.*}/util-linux-${SYNO_UTIL_LINUX_VER}.tar.xz" \
    "util-linux-${SYNO_UTIL_LINUX_VER}" "include/uuid/uuid.h" \
    --disable-all-programs --enable-libuuid --disable-use-tty-group \
    --without-python --disable-makeinstall-chown --disable-nls
  kotv_syno_export_deps_env
}

kotv_syno_ensure_deps_jre() {
  kotv_syno_load_versions
  echo "[deps] profile=jre (OpenJDK required libs + X11)"
  kotv_syno_dep_zlib
  kotv_syno_export_deps_env
  kotv_syno_dep_autotools expat "$SYNO_EXPAT_VER" \
    "https://github.com/libexpat/libexpat/releases/download/R_${SYNO_EXPAT_VER//./_}/expat-${SYNO_EXPAT_VER}.tar.gz" \
    "expat-${SYNO_EXPAT_VER}" "include/expat.h" \
    --without-docbook --without-xmlwf --disable-shared --enable-static
  kotv_syno_dep_autotools freetype "$SYNO_FREETYPE_VER" \
    "https://download.savannah.gnu.org/releases/freetype/freetype-${SYNO_FREETYPE_VER}.tar.gz" \
    "freetype-${SYNO_FREETYPE_VER}" "include/freetype2/ft2build.h" \
    --with-zlib=yes --without-harfbuzz --without-brotli --without-png \
    --disable-shared --enable-static
  kotv_syno_export_deps_env
  kotv_syno_dep_autotools fontconfig "$SYNO_FONTCONFIG_VER" \
    "https://www.freedesktop.org/software/fontconfig/release/fontconfig-${SYNO_FONTCONFIG_VER}.tar.xz" \
    "fontconfig-${SYNO_FONTCONFIG_VER}" "include/fontconfig/fontconfig.h" \
    --disable-docs --disable-nls --enable-static --disable-shared \
    --with-expat="$(kotv_syno_deps_prefix)"
  kotv_syno_dep_cups
  kotv_syno_dep_autotools alsa "$SYNO_ALSA_VER" \
    "https://www.alsa-project.org/files/pub/lib/alsa-lib-${SYNO_ALSA_VER}.tar.bz2" \
    "alsa-lib-${SYNO_ALSA_VER}" "include/alsa/asoundlib.h" \
    --disable-python --disable-alisp --with-sysroot="$SYSROOT"
  kotv_syno_ensure_x11
  kotv_syno_export_deps_env
}

kotv_syno_ensure_deps_ffmpeg() {
  kotv_syno_load_versions
  echo "[deps] profile=ffmpeg (zlib openssl)"
  kotv_syno_dep_zlib
  kotv_syno_dep_openssl
  kotv_syno_export_deps_env
}

# Chromium：官方 hermetic Debian sysroot（glibc 2.31 ≤ DSM 7.2 的 2.36，可跑）
# Toolkit sysroot 缺 Clang/lld 的 crt/libgcc，且头文件无 HWCAP2_*，不硬接
kotv_syno_ensure_deps_chromium() {
  local chrome_src="${1:-}" arch_arg
  case "$PLATFORM" in
    geminilake) arch_arg=amd64 ;;
    rtd1296)    arch_arg=arm64 ;;
    *) echo "ERROR: unknown PLATFORM=$PLATFORM" >&2; return 1 ;;
  esac
  if [[ -z "$chrome_src" || ! -d "$chrome_src" ]]; then
    echo "[deps] profile=chromium — src not ready yet (install-sysroot later)"
    return 0
  fi
  echo "[deps] profile=chromium — hermetic Debian sysroot ($arch_arg)"
  if [[ ! -f "$chrome_src/build/linux/sysroot_scripts/install-sysroot.py" ]]; then
    echo "ERROR: missing install-sysroot.py under $chrome_src" >&2
    return 1
  fi
  (cd "$chrome_src" && python3 build/linux/sysroot_scripts/install-sysroot.py --arch="$arch_arg")
}

# X11：始终编进 deps（完整闭包，避免 sysroot 半套头文件）
# glibc：malloc(0) 非 NULL → 交叉时必须显式 --disable-malloc0returnsnull
kotv_syno_ensure_x11() {
  kotv_syno_load_versions
  local deps x="https://www.x.org/archive/individual"
  local xstack_ver="${SYNO_LIBX11_VER}+xfixes${SYNO_LIBXFIXES_VER}"
  deps="$(kotv_syno_deps_prefix)"
  if kotv_syno_dep_ok x11-stack "$xstack_ver" "include/X11/Xlib.h" \
    && [[ -f "$deps/include/X11/extensions/Xfixes.h" ]] \
    && [[ -f "$deps/include/X11/Intrinsic.h" ]] \
    && [[ -f "$deps/share/pkgconfig/xtrans.pc" || -f "$deps/lib/pkgconfig/xtrans.pc" ]]; then
    echo "[deps] X11 stack cache hit"
    export KOTV_SYNO_X11_PREFIX="$deps"
    return 0
  fi
  echo "[deps] building X11 stack into Toolkit deps"
  # util-macros → xorg-macros.pc；xtrans 为 libX11 硬依赖
  kotv_syno_dep_autotools util-macros "$SYNO_UTIL_MACROS_VER" \
    "${x}/util/util-macros-${SYNO_UTIL_MACROS_VER}.tar.xz" \
    "util-macros-${SYNO_UTIL_MACROS_VER}" "share/pkgconfig/xorg-macros.pc"
  kotv_syno_export_deps_env
  kotv_syno_dep_autotools xorgproto "$SYNO_XORGPROTO_VER" \
    "${x}/proto/xorgproto-${SYNO_XORGPROTO_VER}.tar.xz" \
    "xorgproto-${SYNO_XORGPROTO_VER}" "include/X11/X.h"
  kotv_syno_export_deps_env
  kotv_syno_dep_autotools xtrans "$SYNO_XTRANS_VER" \
    "${x}/lib/xtrans-${SYNO_XTRANS_VER}.tar.xz" \
    "xtrans-${SYNO_XTRANS_VER}" "share/pkgconfig/xtrans.pc"
  kotv_syno_export_deps_env
  kotv_syno_dep_autotools libXau "$SYNO_LIBXAU_VER" \
    "${x}/lib/libXau-${SYNO_LIBXAU_VER}.tar.xz" \
    "libXau-${SYNO_LIBXAU_VER}" "include/X11/Xauth.h" \
    --enable-static --disable-shared
  kotv_syno_dep_autotools xcb-proto "$SYNO_XCB_PROTO_VER" \
    "${x}/proto/xcb-proto-${SYNO_XCB_PROTO_VER}.tar.xz" \
    "xcb-proto-${SYNO_XCB_PROTO_VER}" "share/pkgconfig/xcb-proto.pc"
  kotv_syno_export_deps_env
  kotv_syno_dep_autotools libxcb "$SYNO_LIBXCB_VER" \
    "${x}/lib/libxcb-${SYNO_LIBXCB_VER}.tar.xz" \
    "libxcb-${SYNO_LIBXCB_VER}" "include/xcb/xcb.h" \
    --enable-static --disable-shared --disable-devel-docs
  kotv_syno_export_deps_env
  kotv_syno_dep_autotools libX11 "$SYNO_LIBX11_VER" \
    "${x}/lib/libX11-${SYNO_LIBX11_VER}.tar.xz" \
    "libX11-${SYNO_LIBX11_VER}" "include/X11/Xlib.h" \
    --enable-static --disable-shared --disable-specs \
    --disable-malloc0returnsnull
  kotv_syno_dep_autotools libXext "$SYNO_LIBXEXT_VER" \
    "${x}/lib/libXext-${SYNO_LIBXEXT_VER}.tar.xz" \
    "libXext-${SYNO_LIBXEXT_VER}" "include/X11/extensions/Xext.h" \
    --enable-static --disable-shared --disable-malloc0returnsnull
  kotv_syno_dep_autotools libXrender "$SYNO_LIBXRENDER_VER" \
    "${x}/lib/libXrender-${SYNO_LIBXRENDER_VER}.tar.xz" \
    "libXrender-${SYNO_LIBXRENDER_VER}" "include/X11/extensions/Xrender.h" \
    --enable-static --disable-shared --disable-malloc0returnsnull
  # libXi / libXrandr 依赖 Xfixes
  kotv_syno_dep_autotools libXfixes "$SYNO_LIBXFIXES_VER" \
    "${x}/lib/libXfixes-${SYNO_LIBXFIXES_VER}.tar.xz" \
    "libXfixes-${SYNO_LIBXFIXES_VER}" "include/X11/extensions/Xfixes.h" \
    --enable-static --disable-shared
  kotv_syno_dep_autotools libXrandr "$SYNO_LIBXRANDR_VER" \
    "${x}/lib/libXrandr-${SYNO_LIBXRANDR_VER}.tar.xz" \
    "libXrandr-${SYNO_LIBXRANDR_VER}" "include/X11/extensions/Xrandr.h" \
    --enable-static --disable-shared --disable-malloc0returnsnull
  kotv_syno_dep_autotools libXi "$SYNO_LIBXI_VER" \
    "${x}/lib/libXi-${SYNO_LIBXI_VER}.tar.xz" \
    "libXi-${SYNO_LIBXI_VER}" "include/X11/extensions/XInput.h" \
    --enable-static --disable-shared --disable-malloc0returnsnull
  kotv_syno_dep_autotools libXtst "$SYNO_LIBXTST_VER" \
    "${x}/lib/libXtst-${SYNO_LIBXTST_VER}.tar.xz" \
    "libXtst-${SYNO_LIBXTST_VER}" "include/X11/extensions/XTest.h" \
    --enable-static --disable-shared --disable-malloc0returnsnull
  kotv_syno_dep_autotools libICE "$SYNO_LIBICE_VER" \
    "${x}/lib/libICE-${SYNO_LIBICE_VER}.tar.xz" \
    "libICE-${SYNO_LIBICE_VER}" "include/X11/ICE/ICE.h" \
    --enable-static --disable-shared
  kotv_syno_dep_autotools libSM "$SYNO_LIBSM_VER" \
    "${x}/lib/libSM-${SYNO_LIBSM_VER}.tar.xz" \
    "libSM-${SYNO_LIBSM_VER}" "include/X11/SM/SMlib.h" \
    --enable-static --disable-shared
  kotv_syno_dep_autotools libXt "$SYNO_LIBXT_VER" \
    "${x}/lib/libXt-${SYNO_LIBXT_VER}.tar.xz" \
    "libXt-${SYNO_LIBXT_VER}" "include/X11/Intrinsic.h" \
    --enable-static --disable-shared --disable-malloc0returnsnull
  kotv_syno_dep_mark x11-stack "$xstack_ver"
  export KOTV_SYNO_X11_PREFIX="$deps"
}

kotv_syno_ensure_deps() {
  local profile="${1:?usage: kotv_syno_ensure_deps <node|python|jre|ffmpeg|chromium> [chromium_src]}"
  mkdir -p "$(kotv_syno_deps_prefix)"
  case "$profile" in
    node)     kotv_syno_ensure_deps_node ;;
    python)   kotv_syno_ensure_deps_python ;;
    jre)      kotv_syno_ensure_deps_jre ;;
    ffmpeg)   kotv_syno_ensure_deps_ffmpeg ;;
    chromium) kotv_syno_ensure_deps_chromium "${2:-}" ;;
    *) echo "ERROR: unknown deps profile: $profile" >&2; return 1 ;;
  esac
}
