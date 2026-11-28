#!/usr/bin/env bash
# 用已 export 的 Toolkit 工具链，在独立 deps 前缀下编译运行时外部库。
# 由 build-runtime-in-chroot.sh source（需已定义 download；且有
# PLATFORM/CC/CXX/SYSROOT/CFLAGS/LDFLAGS/SRC_CACHE/BUILD_ROOT）。
#
# 原则：目标链接只用此前缀或 Toolkit sysroot，绝不用宿主 /usr。
# 清单来自上游文档（CPython configure optional modules、OpenJDK 21 building.md），
# 按组件 profile 一次备齐，而不是编到报错再补。
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

# 挂上 deps 搜索路径；清空 PKG_CONFIG_SYSROOT_DIR，避免双重 sysroot 路径。
kotv_syno_export_deps_env() {
  local deps
  deps="$(kotv_syno_deps_prefix)"
  export PKG_CONFIG_SYSROOT_DIR=""
  export PKG_CONFIG_LIBDIR="${deps}/lib/pkgconfig:${deps}/lib64/pkgconfig:${deps}/share/pkgconfig"
  export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"
  # 保留工具链 --sysroot，只追加 deps 的 -I/-L
  case " ${CPPFLAGS:-} " in
    *" -I${deps}/include "*) ;;
    *) export CPPFLAGS="-I${deps}/include ${CPPFLAGS:-}" ;;
  esac
  case " ${LDFLAGS:-} " in
    *" -L${deps}/lib "*) ;;
    *) export LDFLAGS="-L${deps}/lib -L${deps}/lib64 ${LDFLAGS:-}" ;;
  esac
}

kotv_syno_deps_ship_shared() {
  local dest_lib="$1"
  shift
  local deps name
  deps="$(kotv_syno_deps_prefix)"
  mkdir -p "$dest_lib"
  for name in "$@"; do
    cp -a "${deps}/lib/lib${name}.so"* "$dest_lib/" 2>/dev/null || true
    cp -a "${deps}/lib64/lib${name}.so"* "$dest_lib/" 2>/dev/null || true
  done
}

# ---------- 通用：stamp / 解压 / autotools ----------

kotv_syno_dep_ok() {
  # $1=name $2=ver $3=探针文件（相对 deps 前缀）
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

kotv_syno_dep_extract() {
  # $1=tarball $2=期望解压出的目录名（BUILD_ROOT 下）
  local tarball="$1" src="$BUILD_ROOT/$2"
  rm -rf "$src"
  mkdir -p "$BUILD_ROOT"
  case "$tarball" in
    *.tar.gz|*.tgz) tar -xzf "$tarball" -C "$BUILD_ROOT" ;;
    *.tar.xz)       tar -xJf "$tarball" -C "$BUILD_ROOT" ;;
    *.tar.bz2)      tar -xjf "$tarball" -C "$BUILD_ROOT" ;;
    *) echo "ERROR: unknown archive: $tarball" >&2; return 1 ;;
  esac
  echo "$src"
}

kotv_syno_dep_autotools() {
  # $1=name $2=ver $3=url $4=dirname $5=probe 其余=configure 额外参数
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
  tarball="$SRC_CACHE/$(basename "$url")"
  download "$url" "$tarball"
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

# ---------- 单库（特殊构建系统）----------

kotv_syno_dep_zlib() {
  kotv_syno_load_versions
  local ver="$SYNO_ZLIB_VER" deps host jobs tarball src
  if kotv_syno_dep_ok zlib "$ver" "include/zlib.h"; then
    echo "[deps] zlib $ver cache hit"; return 0
  fi
  deps="$(kotv_syno_deps_prefix)"; host="$(kotv_syno_deps_host_triple)"; jobs="$(kotv_syno_njobs)"
  tarball="$SRC_CACHE/zlib-${ver}.tar.gz"
  download "https://www.zlib.net/fossils/zlib-${ver}.tar.gz" "$tarball"
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
  tarball="$SRC_CACHE/bzip2-${ver}.tar.gz"
  download "https://sourceware.org/pub/bzip2/bzip2-${ver}.tar.gz" "$tarball"
  src="$(kotv_syno_dep_extract "$tarball" "bzip2-${ver}")"
  mkdir -p "$deps" "$deps/lib" "$deps/include" "$deps/bin" "$deps/man/man1"
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

kotv_syno_dep_zstd() {
  kotv_syno_load_versions
  local ver="$SYNO_ZSTD_VER" deps jobs tarball src
  if kotv_syno_dep_ok zstd "$ver" "include/zstd.h"; then
    echo "[deps] zstd $ver cache hit"; return 0
  fi
  deps="$(kotv_syno_deps_prefix)"; jobs="$(kotv_syno_njobs)"
  tarball="$SRC_CACHE/zstd-${ver}.tar.gz"
  download "https://github.com/facebook/zstd/releases/download/v${ver}/zstd-${ver}.tar.gz" "$tarball"
  src="$(kotv_syno_dep_extract "$tarball" "zstd-${ver}")"
  mkdir -p "$deps"
  (
    cd "$src"
    make -j"$jobs" -C lib CC="$CC" AR="$AR" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" \
      prefix="$deps" install
  )
  kotv_syno_dep_mark zstd "$ver"
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
  tarball="$SRC_CACHE/openssl-${ver}.tar.gz"
  download "https://github.com/openssl/openssl/releases/download/openssl-${ver}/openssl-${ver}.tar.gz" "$tarball"
  src="$(kotv_syno_dep_extract "$tarball" "openssl-${ver}")"
  mkdir -p "$deps"
  (
    cd "$src"
    # 交叉时 CC 已是 Toolkit 前缀编译器；Configure 目标三元组按 PLATFORM 选
    ./Configure "$target" \
      --prefix="$deps" --openssldir="$deps/ssl" \
      --libdir=lib \
      no-tests no-docs \
      "CC=$CC" "CXX=$CXX" "CFLAGS=$CFLAGS" "LDFLAGS=$LDFLAGS"
    make -j"$jobs"
    make install_sw
  )
  kotv_syno_dep_mark openssl "$ver"
}

# ---------- 组件 profile ----------

# CPython optional modules：https://docs.python.org/3/using/configure.html
kotv_syno_ensure_deps_python() {
  kotv_syno_load_versions
  echo "[deps] profile=python (CPython optional modules)"
  kotv_syno_dep_zlib
  kotv_syno_export_deps_env
  kotv_syno_dep_bzip2
  kotv_syno_dep_autotools xz "$SYNO_XZ_VER" \
    "https://github.com/tukaani-project/xz/releases/download/v${SYNO_XZ_VER}/xz-${SYNO_XZ_VER}.tar.gz" \
    "xz-${SYNO_XZ_VER}" "include/lzma.h" \
    --disable-doc --disable-scripts --disable-xzdec --disable-lzmadec
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
    --disable-static --enable-threadsafe
  kotv_syno_dep_autotools ncurses "$SYNO_NCURSES_VER" \
    "https://ftp.gnu.org/gnu/ncurses/ncurses-${SYNO_NCURSES_VER}.tar.gz" \
    "ncurses-${SYNO_NCURSES_VER}" "include/ncursesw/curses.h" \
    --with-shared --without-debug --without-ada --enable-widec \
    --enable-pc-files --with-pkg-config-libdir="$(kotv_syno_deps_prefix)/lib/pkgconfig"
  # widec 头在 include/ncursesw；给 readline/python 兜软链
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

# OpenJDK 21：alsa / cups / fontconfig 不可关；X11 头文件即便 headless 也要
# https://github.com/openjdk/jdk21/blob/master/doc/building.md
kotv_syno_ensure_deps_jre() {
  kotv_syno_load_versions
  echo "[deps] profile=jre (OpenJDK required libs)"
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
  kotv_syno_dep_autotools cups "$SYNO_CUPS_VER" \
    "https://github.com/OpenPrinting/cups/releases/download/v${SYNO_CUPS_VER}/cups-${SYNO_CUPS_VER}-source.tar.gz" \
    "cups-${SYNO_CUPS_VER}" "include/cups/cups.h" \
    --disable-libusb --disable-dbus --disable-pam --disable-gssapi \
    --disable-systemd --with-tls=no --disable-browsing
  kotv_syno_dep_autotools alsa "$SYNO_ALSA_VER" \
    "https://www.alsa-project.org/files/pub/lib/alsa-lib-${SYNO_ALSA_VER}.tar.bz2" \
    "alsa-lib-${SYNO_ALSA_VER}" "include/alsa/asoundlib.h" \
    --disable-python --disable-alisp --with-sysroot="$SYSROOT"
  kotv_syno_ensure_x11
  kotv_syno_export_deps_env
}

kotv_syno_ensure_deps_ffmpeg() {
  kotv_syno_load_versions
  echo "[deps] profile=ffmpeg"
  kotv_syno_dep_zlib
  kotv_syno_dep_openssl
  kotv_syno_export_deps_env
}

# Node 默认把 openssl/zlib/icu 等编进二进制；Chromium headless.gn + third_party 自带库。
# 二者不链宿主系统库；此处仅声明，避免误以为漏编。
kotv_syno_ensure_deps_node() {
  echo "[deps] profile=node — upstream bundles native deps; no Toolkit overlay"
}

kotv_syno_ensure_deps_chromium() {
  echo "[deps] profile=chromium — headless.gn + third_party; no Toolkit overlay"
}

# X11：OpenJDK 需要 Xlib/Xext/Xrender/Xrandr/XTest/Xt 头文件。
# 优先 Toolkit sysroot（属工具链环境，非宿主）；缺失则自编进 deps。
kotv_syno_ensure_x11() {
  kotv_syno_load_versions
  local deps xroot
  deps="$(kotv_syno_deps_prefix)"
  if [[ -f "$SYSROOT/usr/include/X11/Xlib.h" \
     && -f "$SYSROOT/usr/include/X11/extensions/Xrandr.h" \
     && -f "$SYSROOT/usr/include/X11/extensions/XTest.h" \
     && -f "$SYSROOT/usr/include/X11/Intrinsic.h" ]]; then
    echo "[deps] X11 headers in Toolkit sysroot"
    export KOTV_SYNO_X11_PREFIX="$SYSROOT/usr"
    return 0
  fi
  if kotv_syno_dep_ok x11-stack "$SYNO_LIBX11_VER" "include/X11/Xlib.h" \
    && [[ -f "$deps/include/X11/Intrinsic.h" ]]; then
    echo "[deps] X11 stack cache hit"
    export KOTV_SYNO_X11_PREFIX="$deps"
    return 0
  fi
  echo "[deps] building X11 stack into Toolkit deps (sysroot incomplete)"
  local x="https://www.x.org/archive/individual"
  kotv_syno_dep_autotools xorgproto "$SYNO_XORGPROTO_VER" \
    "${x}/proto/xorgproto-${SYNO_XORGPROTO_VER}.tar.xz" \
    "xorgproto-${SYNO_XORGPROTO_VER}" "include/X11/X.h"
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
    --enable-static --disable-shared --disable-specs
  kotv_syno_dep_autotools libXext "$SYNO_LIBXEXT_VER" \
    "${x}/lib/libXext-${SYNO_LIBXEXT_VER}.tar.xz" \
    "libXext-${SYNO_LIBXEXT_VER}" "include/X11/extensions/Xext.h" \
    --enable-static --disable-shared
  kotv_syno_dep_autotools libXrender "$SYNO_LIBXRENDER_VER" \
    "${x}/lib/libXrender-${SYNO_LIBXRENDER_VER}.tar.xz" \
    "libXrender-${SYNO_LIBXRENDER_VER}" "include/X11/extensions/Xrender.h" \
    --enable-static --disable-shared
  kotv_syno_dep_autotools libXrandr "$SYNO_LIBXRANDR_VER" \
    "${x}/lib/libXrandr-${SYNO_LIBXRANDR_VER}.tar.xz" \
    "libXrandr-${SYNO_LIBXRANDR_VER}" "include/X11/extensions/Xrandr.h" \
    --enable-static --disable-shared
  kotv_syno_dep_autotools libXi "$SYNO_LIBXI_VER" \
    "${x}/lib/libXi-${SYNO_LIBXI_VER}.tar.xz" \
    "libXi-${SYNO_LIBXI_VER}" "include/X11/extensions/XInput.h" \
    --enable-static --disable-shared
  kotv_syno_dep_autotools libXtst "$SYNO_LIBXTST_VER" \
    "${x}/lib/libXtst-${SYNO_LIBXTST_VER}.tar.xz" \
    "libXtst-${SYNO_LIBXTST_VER}" "include/X11/extensions/XTest.h" \
    --enable-static --disable-shared
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
    --enable-static --disable-shared
  kotv_syno_dep_mark x11-stack "$SYNO_LIBX11_VER"
  export KOTV_SYNO_X11_PREFIX="$deps"
}

# 统一入口：按组件备齐依赖并 export 搜索路径
kotv_syno_ensure_deps() {
  local profile="${1:?usage: kotv_syno_ensure_deps <python|jre|ffmpeg|node|chromium>}"
  mkdir -p "$(kotv_syno_deps_prefix)"
  case "$profile" in
    python)   kotv_syno_ensure_deps_python ;;
    jre)      kotv_syno_ensure_deps_jre ;;
    ffmpeg)   kotv_syno_ensure_deps_ffmpeg ;;
    node)     kotv_syno_ensure_deps_node ;;
    chromium) kotv_syno_ensure_deps_chromium ;;
    *) echo "ERROR: unknown deps profile: $profile" >&2; return 1 ;;
  esac
}
