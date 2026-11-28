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
  # CPython 把 libffi.a 链进 _ctypes.so，必须 -fPIC；stamp 带 -pic 逼旧 cache 失效
  CFLAGS="${CFLAGS:-} -fPIC" kotv_syno_dep_autotools libffi "${SYNO_LIBFFI_VER}-pic" \
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

# ---------- jellyfin-ffmpeg HWA：libpciaccess → libdrm → libva(drm) ----------
kotv_syno_dep_libpciaccess() {
  kotv_syno_load_versions
  # shared：供 libdrm.so / 运行时 VAAPI 链路
  kotv_syno_dep_autotools libpciaccess "$SYNO_LIBPCIACCESS_VER" \
    "https://xorg.freedesktop.org/archive/individual/lib/libpciaccess-${SYNO_LIBPCIACCESS_VER}.tar.xz" \
    "libpciaccess-${SYNO_LIBPCIACCESS_VER}" "include/pciaccess.h" \
    --enable-shared --disable-static
}

kotv_syno_dep_meson_lib() {
  # $1=name $2=ver $3=url $4=dirname $5=probe 其余=meson 选项
  local name="$1" ver="$2" url="$3" dirname="$4" probe="$5"
  shift 5
  local deps host jobs tarball src
  if kotv_syno_dep_ok "$name" "$ver" "$probe"; then
    echo "[deps] $name $ver cache hit"
    return 0
  fi
  if ! command -v meson >/dev/null 2>&1 || ! command -v ninja >/dev/null 2>&1; then
    echo "ERROR: meson+ninja required to build $name" >&2
    return 1
  fi
  deps="$(kotv_syno_deps_prefix)"
  host="$(kotv_syno_deps_host_triple)"
  jobs="$(kotv_syno_njobs)"
  tarball="$(kotv_syno_dep_fetch "$url")"
  src="$(kotv_syno_dep_extract "$tarball" "$dirname")"
  mkdir -p "$deps"
  (
    cd "$src"
    local mconf=(
      --prefix="$deps"
      --libdir=lib
      --buildtype=release
      --default-library=shared
      "$@"
    )
    if [[ "$PLATFORM" == rtd1296 ]]; then
      # 交叉：写临时 meson cross file
      local xf="$BUILD_ROOT/meson-cross-${PLATFORM}.txt"
      cat >"$xf" <<EOF
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '${AR:-ar}'
strip = '${STRIP:-strip}'
pkg-config = '$(command -v pkg-config)'

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[built-in options]
c_args = ['--sysroot=${SYSROOT}', '-I${deps}/include']
c_link_args = ['--sysroot=${SYSROOT}', '-L${deps}/lib']
cpp_args = ['--sysroot=${SYSROOT}', '-I${deps}/include']
cpp_link_args = ['--sysroot=${SYSROOT}', '-L${deps}/lib']
EOF
      mconf+=(--cross-file="$xf")
    fi
    meson setup build "${mconf[@]}"
    ninja -C build -j"$jobs"
    ninja -C build install
  )
  kotv_syno_dep_mark "$name" "$ver"
}

kotv_syno_dep_libdrm() {
  kotv_syno_load_versions
  local ver="$SYNO_LIBDRM_VER"
  kotv_syno_export_deps_env
  kotv_syno_dep_meson_lib libdrm "$ver" \
    "https://dri.freedesktop.org/libdrm/libdrm-${ver}.tar.xz" \
    "libdrm-${ver}" "include/libdrm/drm.h" \
    -Dudev=false -Dcairo-tests=disabled -Dvalgrind=disabled \
    -Dexynos=disabled -Dfreedreno=disabled -Domap=disabled -Detnaviv=disabled \
    -Dintel=enabled -Dnouveau=disabled -Dradeon=disabled -Damdgpu=disabled \
    -Dinstall-test-programs=false
}

kotv_syno_dep_libva() {
  # drm-only（群晖无桌面 X11）；运行时靠 DSM /dev/dri + LIBVA_DRIVERS_PATH
  kotv_syno_load_versions
  local ver="$SYNO_LIBVA_VER" deps
  kotv_syno_export_deps_env
  deps="$(kotv_syno_deps_prefix)"
  kotv_syno_dep_meson_lib libva "$ver" \
    "https://github.com/intel/libva/archive/refs/tags/${ver}.tar.gz" \
    "libva-${ver}" "include/va/va.h" \
    -Denable_docs=false \
    -Dwith_x11=no -Dwith_glx=no -Dwith_wayland=no \
    -Ddisable_drm=false \
    -Ddriverdir="${deps}/lib/dri"
}

# CUDA/NVENC：nv-codec-headers（纯头文件 + ffnvcodec.pc）；运行时 dlopen libcuda/libnvidia-encode
kotv_syno_dep_ffnvcodec() {
  kotv_syno_load_versions
  local ver="$SYNO_FFNVCODEC_VER" deps jobs tarball src
  if kotv_syno_dep_ok ffnvcodec "$ver" "lib/pkgconfig/ffnvcodec.pc"; then
    echo "[deps] ffnvcodec $ver cache hit"; return 0
  fi
  deps="$(kotv_syno_deps_prefix)"; jobs="$(kotv_syno_njobs)"
  tarball="$(kotv_syno_dep_fetch "https://github.com/FFmpeg/nv-codec-headers/archive/refs/tags/${ver}.tar.gz")"
  src="$(kotv_syno_dep_extract "$tarball" "nv-codec-headers-${ver}")"
  mkdir -p "$deps"
  (
    cd "$src"
    make PREFIX="$deps" install
  )
  kotv_syno_dep_mark ffnvcodec "$ver"
}

# QSV：Intel oneVPL（仅 geminilake）；运行时需 DSM 上的 VPL/MediaSDK GPU runtime
kotv_syno_dep_libvpl() {
  kotv_syno_load_versions
  local ver="$SYNO_LIBVPL_VER" deps jobs tarball src
  if [[ "$PLATFORM" != geminilake ]]; then
    echo "[deps] libvpl skip (QSV x86 only, PLATFORM=$PLATFORM)"
    return 0
  fi
  if kotv_syno_dep_ok libvpl "$ver" "lib/pkgconfig/vpl.pc"; then
    echo "[deps] libvpl $ver cache hit"; return 0
  fi
  if ! command -v cmake >/dev/null 2>&1 || ! command -v ninja >/dev/null 2>&1; then
    echo "ERROR: cmake+ninja required for libvpl" >&2
    return 1
  fi
  deps="$(kotv_syno_deps_prefix)"; jobs="$(kotv_syno_njobs)"
  tarball="$(kotv_syno_dep_fetch "https://github.com/intel/libvpl/archive/refs/tags/v${ver}.tar.gz")"
  src="$(kotv_syno_dep_extract "$tarball" "libvpl-${ver}")"
  mkdir -p "$deps"
  (
    cd "$src"
    cmake -GNinja -S . -B build \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="$deps" \
      -DCMAKE_C_COMPILER="$CC" \
      -DCMAKE_CXX_COMPILER="$CXX" \
      -DCMAKE_SYSROOT="$SYSROOT" \
      -DCMAKE_C_FLAGS="$CFLAGS" \
      -DCMAKE_CXX_FLAGS="$CXXFLAGS" \
      -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS" \
      -DCMAKE_SHARED_LINKER_FLAGS="$LDFLAGS" \
      -DINSTALL_DEV=ON -DINSTALL_LIB=ON -DINSTALL_EXAMPLES=OFF \
      -DBUILD_EXAMPLES=OFF -DBUILD_EXPERIMENTAL=OFF \
      -DBUILD_SHARED_LIBS=ON -DBUILD_TESTS=OFF
    ninja -C build -j"$jobs"
    ninja -C build install
    # ffmpeg pkg-config 名是 vpl
    if [[ -f "$deps/lib/pkgconfig/vpl.pc" ]]; then
      grep -q 'lstdc++' "$deps/lib/pkgconfig/vpl.pc" \
        || echo "Libs.private: -lstdc++" >>"$deps/lib/pkgconfig/vpl.pc"
    fi
  )
  kotv_syno_dep_mark libvpl "$ver"
}

# rkmpp：Rockchip MPP（rtd1296 备用；nyanmisaka jellyfin-mpp-next）
kotv_syno_dep_rkmpp() {
  kotv_syno_load_versions
  local ver="$SYNO_RKMPP_COMMIT" deps jobs tarball src
  if [[ "$PLATFORM" != rtd1296 ]]; then
    echo "[deps] rkmpp skip (arm only, PLATFORM=$PLATFORM)"
    return 0
  fi
  if kotv_syno_dep_ok rkmpp "$ver" "lib/pkgconfig/rockchip_mpp.pc"; then
    echo "[deps] rkmpp $ver cache hit"; return 0
  fi
  if ! command -v cmake >/dev/null 2>&1 || ! command -v ninja >/dev/null 2>&1; then
    echo "ERROR: cmake+ninja required for rkmpp" >&2
    return 1
  fi
  deps="$(kotv_syno_deps_prefix)"; jobs="$(kotv_syno_njobs)"
  tarball="$(kotv_syno_dep_fetch "https://github.com/nyanmisaka/rk-mirrors/archive/${ver}.tar.gz")"
  # github：rk-mirrors-<commit>
  src="$(kotv_syno_dep_extract "$tarball" "rk-mirrors-${ver}")"
  mkdir -p "$deps"
  (
    cd "$src"
    cmake -GNinja -S . -B build \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="$deps" \
      -DCMAKE_SYSTEM_NAME=Linux \
      -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
      -DCMAKE_C_COMPILER="$CC" \
      -DCMAKE_CXX_COMPILER="$CXX" \
      -DCMAKE_SYSROOT="$SYSROOT" \
      -DCMAKE_C_FLAGS="$CFLAGS" \
      -DCMAKE_CXX_FLAGS="$CXXFLAGS" \
      -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS" \
      -DCMAKE_SHARED_LINKER_FLAGS="$LDFLAGS" \
      -DBUILD_TEST=OFF \
      -DBUILD_SHARED_LIBS=ON
    ninja -C build -j"$jobs"
    ninja -C build install
    if [[ -f "$deps/lib/pkgconfig/rockchip_mpp.pc" ]]; then
      grep -q 'lstdc++' "$deps/lib/pkgconfig/rockchip_mpp.pc" \
        || echo "Libs.private: -lstdc++" >>"$deps/lib/pkgconfig/rockchip_mpp.pc"
    fi
  )
  kotv_syno_dep_mark rkmpp "$ver"
}

# rkrga：Rockchip RGA（与 rkmpp 配对）
kotv_syno_dep_rkrga() {
  kotv_syno_load_versions
  local ver="$SYNO_RKRGA_COMMIT" deps jobs tarball src
  if [[ "$PLATFORM" != rtd1296 ]]; then
    echo "[deps] rkrga skip (arm only, PLATFORM=$PLATFORM)"
    return 0
  fi
  if kotv_syno_dep_ok rkrga "$ver" "lib/pkgconfig/librga.pc"; then
    echo "[deps] rkrga $ver cache hit"; return 0
  fi
  deps="$(kotv_syno_deps_prefix)"; jobs="$(kotv_syno_njobs)"
  tarball="$(kotv_syno_dep_fetch "https://github.com/nyanmisaka/rk-mirrors/archive/${ver}.tar.gz")"
  src="$(kotv_syno_dep_extract "$tarball" "rk-mirrors-${ver}")"
  kotv_syno_export_deps_env
  # 与 jellyfin 相同：shared_library→library 以便可控；我们改编 shared 便于随包
  (
    cd "$src"
    # 保持 meson 默认 shared
    local mextra=()
    # 复用 meson_lib 的交叉文件逻辑：直接调 meson
    if [[ "$PLATFORM" == rtd1296 ]]; then
      local xf="$BUILD_ROOT/meson-cross-${PLATFORM}-rga.txt"
      cat >"$xf" <<EOF
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '${AR:-ar}'
strip = '${STRIP:-strip}'
pkg-config = '$(command -v pkg-config)'

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[built-in options]
c_args = ['--sysroot=${SYSROOT}', '-I${deps}/include', '-fpermissive']
c_link_args = ['--sysroot=${SYSROOT}', '-L${deps}/lib']
cpp_args = ['--sysroot=${SYSROOT}', '-I${deps}/include', '-fpermissive']
cpp_link_args = ['--sysroot=${SYSROOT}', '-L${deps}/lib']
EOF
      mextra+=(--cross-file="$xf")
    fi
    meson setup build \
      --prefix="$deps" --libdir=lib --buildtype=release \
      --default-library=shared \
      -Dlibdrm=false -Dlibrga_demo=false \
      "${mextra[@]}"
    ninja -C build -j"$jobs"
    ninja -C build install
    if [[ -f "$deps/lib/pkgconfig/librga.pc" ]]; then
      grep -q 'lstdc++' "$deps/lib/pkgconfig/librga.pc" \
        || echo "Libs.private: -lstdc++" >>"$deps/lib/pkgconfig/librga.pc"
    fi
  )
  kotv_syno_dep_mark rkrga "$ver"
}

kotv_syno_ensure_deps_ffmpeg() {
  kotv_syno_load_versions
  echo "[deps] profile=ffmpeg (VAAPI + CUDA/ffnvcodec + QSV/libvpl + rkmpp/rkrga)"
  kotv_syno_dep_zlib
  kotv_syno_dep_openssl
  kotv_syno_export_deps_env
  kotv_syno_dep_libpciaccess
  kotv_syno_export_deps_env
  kotv_syno_dep_libdrm
  kotv_syno_export_deps_env
  kotv_syno_dep_libva
  kotv_syno_export_deps_env
  # 全架构：CUDA 头（群晖 NVIDIA 机型运行时加载）
  kotv_syno_dep_ffnvcodec
  kotv_syno_export_deps_env
  # x86：QSV
  kotv_syno_dep_libvpl
  kotv_syno_export_deps_env
  # arm：rkmpp/rkrga 备用
  kotv_syno_dep_rkmpp
  kotv_syno_export_deps_env
  kotv_syno_dep_rkrga
  kotv_syno_export_deps_env
}

# Chromium headless + Toolkit sysroot：按清单一次补齐（禁止缺啥补啥）
#
# headless.gn 已关：alsa/cups/dbus/gtk/glib/pangocairo/pci/pulse/udev/pipewire…
# 我们再关：use_xkbcommon / use_system_minigbm；libdrm/vaapi 走 bundled 或本身为 false。
# 因此 sysroot 只需：
#   1) Toolkit 底（glibc 2.36 ABI + 标准 crt1/crti…）
#   2) Toolkit GCC 的 crtbeginS/crtendS + libgcc(+libatomic) —— Clang+lld 默认找不到
#   3) dri.pc —— build/config/linux/dri/BUILD.gn：use_sysroot 时 has_dri 恒 true
#   4) HWCAP2_BTI/MTE —— arm64 partition_alloc 需要（Toolkit 头文件过旧）
# 不编 libdrm/xkbcommon/mesa：headless 不走系统包。
kotv_syno_chromium_sysroot() {
  echo "${KOTV_SYNO_CHROMIUM_SYSROOT:-${ROOT:?}/.syno-deps/${PLATFORM:?}-chromium-sysroot}"
}

kotv_syno_chromium_gcc_libdir() {
  local f
  f="$("${CC:?}" -print-file-name=crtbeginS.o 2>/dev/null || true)"
  if [[ -n "$f" && -f "$f" ]]; then
    dirname "$f"
    return 0
  fi
  f="$("$CC" -print-file-name=libgcc.a 2>/dev/null || true)"
  if [[ -n "$f" && -f "$f" ]]; then
    dirname "$f"
    return 0
  fi
  echo "ERROR: cannot locate Toolkit gcc crt/libgcc via $CC" >&2
  return 1
}

kotv_syno_chromium_fill_gcc_rt() {
  local sysroot="$1" gccdir dest mirror triple ver f
  gccdir="$(kotv_syno_chromium_gcc_libdir)" || return 1
  dest="$sysroot/usr/lib"
  mkdir -p "$dest" "$sysroot/lib" "$sysroot/usr/lib64"
  echo "[deps] chromium: seed GCC runtime from $gccdir"
  # 扁平：Clang --sysroot 常在 usr/lib、lib 找 crt/-lgcc
  for f in "$gccdir"/crt*.o "$gccdir"/libgcc* "$gccdir"/libatomic*; do
    [[ -e "$f" ]] || continue
    cp -a "$f" "$dest/"
    cp -a "$f" "$sysroot/lib/"
    cp -a "$f" "$sysroot/usr/lib64/" 2>/dev/null || true
  done
  # 镜像 GCC 布局，兼容 --gcc-toolchain / -B 探测
  triple="$("$CC" -dumpmachine 2>/dev/null || true)"
  ver="$("$CC" -dumpversion 2>/dev/null || true)"
  if [[ -n "$triple" && -n "$ver" ]]; then
    mirror="$sysroot/usr/lib/gcc/${triple}/${ver}"
    mkdir -p "$mirror"
    cp -a "$gccdir"/. "$mirror/" 2>/dev/null || true
  fi
  # 显式保证关键文件名存在（CI 曾挂 crtbeginS / -lgcc）
  for f in crtbeginS.o crtendS.o crtbegin.o crtend.o; do
    if [[ ! -f "$dest/$f" ]]; then
      echo "ERROR: missing $f after GCC runtime fill (from $gccdir)" >&2
      ls -la "$gccdir" | head -60 >&2 || true
      return 1
    fi
  done
  if [[ ! -e "$dest/libgcc.a" && ! -e "$dest/libgcc_s.so" && ! -e "$dest/libgcc_s.so.1" ]]; then
    echo "ERROR: libgcc missing after GCC runtime fill ($gccdir)" >&2
    return 1
  fi
  # -lgcc 有时要 libgcc.so 链接器脚本/别名
  if [[ ! -e "$dest/libgcc.so" && -e "$dest/libgcc_s.so" ]]; then
    ln -sfn libgcc_s.so "$dest/libgcc.so" 2>/dev/null || true
  fi
  if [[ ! -e "$dest/libgcc.so" && -e "$dest/libgcc_s.so.1" ]]; then
    ln -sfn libgcc_s.so.1 "$dest/libgcc.so" 2>/dev/null || true
  fi
  export KOTV_SYNO_CHROMIUM_GCC_LIBDIR="$gccdir"
  echo "$gccdir" >"$sysroot/.kotv-gcc-libdir"
}

kotv_syno_chromium_fill_hwcap2() {
  # Toolkit 头文件缺 HWCAP2_*/PR_MTE_*/SYS_pkey_*。
  # Chromium GN 把 extra_cflags 整串当成单个 argv → 必须用无空格的 -includePATH；
  # 同时把宏写进可写 sysroot 头，并在 checkout 后 patch 源码（三保险）。
  local sysroot="$1" compat hwcap_bits
  mkdir -p "$sysroot/usr/include"
  compat="$sysroot/usr/include/kotv-chromium-compat.h"
  cat >"$compat" <<'EOF'
/* KOTV: Toolkit glibc headers may lack these; force-included for Chromium partition_alloc. */
#pragma once
#ifndef HWCAP2_BTI
#define HWCAP2_BTI (1 << 17)
#endif
#ifndef HWCAP2_MTE
#define HWCAP2_MTE (1 << 18)
#endif
#ifndef PR_MTE_TCF_SHIFT
#define PR_MTE_TCF_SHIFT 1
#endif
#ifndef PR_MTE_TCF_NONE
#define PR_MTE_TCF_NONE (0UL << PR_MTE_TCF_SHIFT)
#endif
#ifndef PR_MTE_TCF_SYNC
#define PR_MTE_TCF_SYNC (1UL << PR_MTE_TCF_SHIFT)
#endif
#ifndef PR_MTE_TCF_ASYNC
#define PR_MTE_TCF_ASYNC (2UL << PR_MTE_TCF_SHIFT)
#endif
#ifndef PR_MTE_TCF_MASK
#define PR_MTE_TCF_MASK (3UL << PR_MTE_TCF_SHIFT)
#endif
#ifndef PR_MTE_TAG_SHIFT
#define PR_MTE_TAG_SHIFT 3
#endif
#ifndef PR_MTE_TAG_MASK
#define PR_MTE_TAG_MASK (0xffffUL << PR_MTE_TAG_SHIFT)
#endif
/* memory-protection keys syscalls (Toolkit headers may omit) */
#if defined(__x86_64__)
#ifndef SYS_pkey_mprotect
#define SYS_pkey_mprotect 329
#endif
#ifndef SYS_pkey_alloc
#define SYS_pkey_alloc 330
#endif
#ifndef SYS_pkey_free
#define SYS_pkey_free 331
#endif
#elif defined(__aarch64__)
#ifndef SYS_pkey_mprotect
#define SYS_pkey_mprotect 288
#endif
#ifndef SYS_pkey_alloc
#define SYS_pkey_alloc 289
#endif
#ifndef SYS_pkey_free
#define SYS_pkey_free 290
#endif
#endif
EOF
  # 直接补进 bits/hwcap.h（rsync 副本可写），不依赖 -include
  hwcap_bits="$sysroot/usr/include/bits/hwcap.h"
  if [[ -f "$hwcap_bits" ]] && ! grep -q 'KOTV_HWCAP2' "$hwcap_bits"; then
    cat >>"$hwcap_bits" <<'EOF'

/* KOTV_HWCAP2: Toolkit glibc too old for Chromium partition_alloc */
#ifndef HWCAP2_BTI
#define HWCAP2_BTI (1 << 17)
#endif
#ifndef HWCAP2_MTE
#define HWCAP2_MTE (1 << 18)
#endif
EOF
    echo "[deps] chromium: patched $hwcap_bits"
  fi
  export KOTV_SYNO_CHROMIUM_COMPAT_H="$compat"
  echo "$compat" >"$sysroot/.kotv-chromium-compat-h"
  echo "[deps] chromium: wrote compat header $compat"
}

# checkout 后补 partition_alloc 源码（extra_cflags 单 argv 不可靠时仍能过）
kotv_syno_chromium_patch_src() {
  local src="${1:?}" f
  f="$src/base/allocator/partition_allocator/src/partition_alloc/aarch64_support.h"
  if [[ -f "$f" ]] && ! grep -q 'KOTV_HWCAP2' "$f"; then
    # 在第一个 #include 之前插入宏，供本头内 HWCAP2_* 使用
    local tmp
    tmp="$(mktemp)"
    {
      echo '/* KOTV_HWCAP2 */'
      echo '#ifndef HWCAP2_BTI'
      echo '#define HWCAP2_BTI (1 << 17)'
      echo '#endif'
      echo '#ifndef HWCAP2_MTE'
      echo '#define HWCAP2_MTE (1 << 18)'
      echo '#endif'
      cat "$f"
    } >"$tmp"
    mv "$tmp" "$f"
    echo "[chromium] patched aarch64_support.h (HWCAP2)"
  fi
  f="$src/base/allocator/partition_allocator/src/partition_alloc/thread_isolation/pkey.cc"
  if [[ -f "$f" ]] && ! grep -q 'KOTV_SYS_PKEY' "$f"; then
    local tmp
    tmp="$(mktemp)"
    {
      echo '/* KOTV_SYS_PKEY */'
      echo '#ifndef SYS_pkey_mprotect'
      echo '# if defined(__x86_64__)'
      echo '#  define SYS_pkey_mprotect 329'
      echo '#  define SYS_pkey_alloc 330'
      echo '#  define SYS_pkey_free 331'
      echo '# elif defined(__aarch64__)'
      echo '#  define SYS_pkey_mprotect 288'
      echo '#  define SYS_pkey_alloc 289'
      echo '#  define SYS_pkey_free 290'
      echo '# endif'
      echo '#endif'
      cat "$f"
    } >"$tmp"
    mv "$tmp" "$f"
    echo "[chromium] patched pkey.cc (SYS_pkey_*)"
  fi
}

kotv_syno_chromium_fill_dri_pc() {
  # use_sysroot=true → //build/config/linux/dri 跳过探测、直接 pkg-config dri
  local sysroot="$1"
  mkdir -p "$sysroot/usr/lib/dri" "$sysroot/usr/lib/pkgconfig" "$sysroot/usr/share/pkgconfig"
  cat >"$sysroot/usr/lib/pkgconfig/dri.pc" <<'EOF'
prefix=/usr
libdir=${prefix}/lib
includedir=${prefix}/include
dridriverdir=${libdir}/dri
Name: dri
Description: DRI stub for Chromium use_sysroot (headless; no system Mesa)
Version: 24.2.8
Cflags:
Libs:
EOF
  cp -a "$sysroot/usr/lib/pkgconfig/dri.pc" "$sysroot/usr/share/pkgconfig/dri.pc"
}

# 编前验收：缺一项就失败，避免长编译中途才爆
kotv_syno_chromium_verify_sysroot() {
  local sysroot="$1"
  local missing=() p
  local need_files=(
    usr/lib/crtbeginS.o
    usr/lib/crtendS.o
    usr/lib/pkgconfig/dri.pc
  )
  # glibc 启动文件应已在 Toolkit 底里
  local glibc_crt=(usr/lib/crt1.o usr/lib/crti.o usr/lib/crtn.o)
  for p in "${need_files[@]}"; do
    [[ -e "$sysroot/$p" ]] || missing+=("$p")
  done
  if [[ ! -e "$sysroot/usr/lib/libgcc.a" \
     && ! -e "$sysroot/usr/lib/libgcc_s.so" \
     && ! -e "$sysroot/usr/lib/libgcc_s.so.1" \
     && ! -e "$sysroot/usr/lib/libgcc.so" ]]; then
    missing+=("usr/lib/libgcc*")
  fi
  for p in "${glibc_crt[@]}"; do
    # 有的 Toolkit 放在 usr/lib64 或 lib
    if [[ ! -e "$sysroot/$p" && ! -e "$sysroot/usr/lib64/$(basename "$p")" \
       && ! -e "$sysroot/lib/$(basename "$p")" ]]; then
      missing+=("$p (glibc)")
    fi
  done
  if [[ ! -f "$sysroot/usr/include/kotv-chromium-compat.h" ]]; then
    missing+=("usr/include/kotv-chromium-compat.h")
  fi
  echo "[deps] chromium sysroot audit ($sysroot):"
  echo "  crtbeginS.o=$([[ -f $sysroot/usr/lib/crtbeginS.o ]] && echo OK || echo MISS)"
  echo "  libgcc=$(ls "$sysroot/usr/lib"/libgcc* 2>/dev/null | tr '\n' ' ' || echo MISS)"
  echo "  dri.pc=$([[ -f $sysroot/usr/lib/pkgconfig/dri.pc ]] && echo OK || echo MISS)"
  echo "  compat.h=$([[ -f $sysroot/usr/include/kotv-chromium-compat.h ]] && echo OK || echo MISS)"
  if ((${#missing[@]})); then
    echo "ERROR: chromium Toolkit sysroot incomplete:" >&2
    printf '  - %s\n' "${missing[@]}" >&2
    return 1
  fi
}

kotv_syno_ensure_deps_chromium() {
  kotv_syno_load_versions
  local sysroot stamp want
  sysroot="$(kotv_syno_chromium_sysroot)"
  export KOTV_SYNO_CHROMIUM_SYSROOT="$sysroot"
  # stamp：清单版本；改清单必须 bump
  want="toolkit-headless:gcc-rt3:dri-pc2:compat-h2-pkey"
  stamp="$sysroot/.kotv-chromium-sysroot"
  if [[ -f "$stamp" && "$(cat "$stamp" 2>/dev/null || true)" == "$want" ]] \
    && kotv_syno_chromium_verify_sysroot "$sysroot"; then
    echo "[deps] profile=chromium — Toolkit sysroot cache hit ($sysroot)"
    if [[ -f "$sysroot/.kotv-gcc-libdir" ]]; then
      export KOTV_SYNO_CHROMIUM_GCC_LIBDIR
      KOTV_SYNO_CHROMIUM_GCC_LIBDIR="$(cat "$sysroot/.kotv-gcc-libdir")"
    fi
    if [[ -f "$sysroot/.kotv-chromium-compat-h" ]]; then
      export KOTV_SYNO_CHROMIUM_COMPAT_H
      KOTV_SYNO_CHROMIUM_COMPAT_H="$(cat "$sysroot/.kotv-chromium-compat-h")"
    fi
    return 0
  fi
  if [[ -z "${SYSROOT:-}" || ! -d "$SYSROOT" ]]; then
    echo "ERROR: Toolkit SYSROOT required for chromium deps" >&2
    return 1
  fi
  if [[ -z "${CC:-}" || ! -x "${CC:-}" ]]; then
    echo "ERROR: Toolkit CC required for chromium deps" >&2
    return 1
  fi
  echo "[deps] profile=chromium — seed Toolkit sysroot + fill checklist → $sysroot"
  mkdir -p "$sysroot"
  rsync -a "${SYSROOT}/" "$sysroot/"
  # overlay 可写：dri.pc / compat / gcc crt 拷贝
  chmod -R u+w "$sysroot" 2>/dev/null || true

  kotv_syno_chromium_fill_gcc_rt "$sysroot"
  kotv_syno_chromium_fill_hwcap2 "$sysroot"
  kotv_syno_chromium_fill_dri_pc "$sysroot"

  kotv_syno_chromium_verify_sysroot "$sysroot" || return 1
  echo "$want" >"$stamp"
  echo "[deps] profile=chromium ready: $sysroot (gcc_libdir=${KOTV_SYNO_CHROMIUM_GCC_LIBDIR:-})"
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
