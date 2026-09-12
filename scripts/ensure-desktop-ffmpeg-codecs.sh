#!/usr/bin/env bash
# 桌面 FFmpeg 外部解码库：dav1d（AV1）+ libxml2 + libaribcaption（日标字幕）。
# 静态装进 PREFIX，与安卓 webhtv 锁的版本对齐。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${KOTV_MPV_BUILD_DIR:-$ROOT/.build/desktop-mpv}"
PREFIX="${KOTV_DESKTOP_FFMPEG_PREFIX:-$BUILD_DIR/prefix}"
# v6: zlib/xz 只装静态库；xz 关 CLI/NLS（交叉 mac 不链 Homebrew libintl）。
STAMP="$PREFIX/.kotv-ffmpeg-codecs-v6"
JOBS="${KOTV_MPV_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "${NUMBER_OF_PROCESSORS:-4}")}"

DAV1D_VER=1.5.4
DAV1D_SHA=54706fc6bc0cdecab7e9593974a4039cc038fca7
DAV1D_REPO=https://github.com/videolan/dav1d.git

XML2_VER=2.15.3
XML2_URL="https://gitlab.gnome.org/GNOME/libxml2/-/archive/v${XML2_VER}/libxml2-v${XML2_VER}.tar.gz"
XML2_SHA=0da50c1415f4ec0364569d2119b1436ba837b31df44af28569d234272c23cf1f

# libxml2 完整压缩：gzip（zlib）+ xz（liblzma），静态进 PREFIX，避免 Windows 缺 .pc。
ZLIB_VER=1.3.1
ZLIB_SHA=9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23
XZ_VER=5.6.4
XZ_SHA=269e3f2e512cbd3314849982014dc199a7b2148cf5c91cedc6db629acdf5e09b

ARIB_VER=1.1.1
ARIB_URL="https://github.com/xqq/libaribcaption/archive/refs/tags/v${ARIB_VER}.tar.gz"
ARIB_SHA=278d03a0a662d00a46178afc64f32535ede2d78c603842b6fd1c55fa9cd44683

need() { command -v "$1" >/dev/null || { echo "need $1" >&2; exit 1; }; }

is_windows() {
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
  esac
  [[ "${OS:-}" == "Windows_NT" ]]
}

# Windows 上系统 pkg-config 常是坏掉的 Strawberry；以 PREFIX 里 .pc/.a 为准。
pc_ready() {
  local name="$1"
  local pc="$PREFIX/lib/pkgconfig/${name}.pc"
  [[ -f "$pc" ]] || return 1
  case "$name" in
    dav1d) [[ -f "$PREFIX/lib/libdav1d.a" || -f "$PREFIX/lib/libdav1d.dll.a" ]] || return 1 ;;
    zlib) [[ -f "$PREFIX/lib/libz.a" || -f "$PREFIX/lib/libzlibstatic.a" ]] || return 1 ;;
    liblzma) [[ -f "$PREFIX/lib/liblzma.a" || -f "$PREFIX/lib/liblzma.dll.a" ]] || return 1 ;;
    libxml-2.0) [[ -f "$PREFIX/lib/libxml2.a" || -f "$PREFIX/lib/libxml2.dll.a" ]] || return 1 ;;
    libaribcaption) [[ -f "$PREFIX/lib/libaribcaption.a" || -f "$PREFIX/lib/libaribcaption.dll.a" ]] || return 1 ;;
  esac
  return 0
}

fetch() {
  local url="$1" dest="$2" sha="$3"
  verify_sha() {
    local f="$1" expect="$2"
    if command -v shasum >/dev/null; then
      echo "$expect  $f" | shasum -a 256 -c -
    elif command -v sha256sum >/dev/null; then
      echo "$expect  $f" | sha256sum -c -
    else
      return 0
    fi
  }
  if [[ -f "$dest" ]] && verify_sha "$dest" "$sha" >/dev/null 2>&1; then
    return 0
  fi
  rm -f "$dest"
  mkdir -p "$(dirname "$dest")"
  curl -fL --retry 5 --retry-delay 2 --retry-all-errors -o "$dest.partial" "$url" \
    || { rm -f "$dest.partial"; return 1; }
  mv -f "$dest.partial" "$dest"
  verify_sha "$dest" "$sha" || { rm -f "$dest"; return 1; }
}

need curl
need tar
need git
need cmake
need meson
need ninja

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
if is_windows || [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
  export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
fi

if [[ -f "$STAMP" ]] && pc_ready dav1d && pc_ready zlib && pc_ready liblzma \
  && pc_ready libxml-2.0 && pc_ready libaribcaption \
  && [[ ! -e "$PREFIX/lib/libz.dylib" && ! -e "$PREFIX/lib/libz.1.dylib" ]]; then
  echo "ok cached ffmpeg codecs (dav1d+zlib+lzma+xml2+arib in PREFIX)"
  exit 0
fi

# 旧缓存可能留下 zlib/lzma dylib，会让 FFmpeg configure 探测可执行文件 Abort。
rm -f "$PREFIX/lib"/libz*.dylib "$PREFIX/lib"/libz.so* \
  "$PREFIX/lib"/liblzma*.dylib "$PREFIX/lib"/liblzma.so* 2>/dev/null || true
# 有共享 zlib 时强制重装静态（pc 仍在会跳过 build）。
if [[ -f "$PREFIX/lib/pkgconfig/zlib.pc" ]] && [[ ! -f "$PREFIX/lib/libz.a" ]]; then
  rm -f "$PREFIX/lib/pkgconfig/zlib.pc"
fi
# stamp 升级后若仍有旧 dylib 痕迹或缺静态库，清掉 zlib.pc 逼重建。
if [[ -e "$PREFIX/lib/libz.dylib" ]] || [[ -e "$PREFIX/share/pkgconfig/zlib.pc" && ! -f "$PREFIX/lib/libz.a" ]]; then
  rm -f "$PREFIX/lib/pkgconfig/zlib.pc" "$PREFIX/share/pkgconfig/zlib.pc"
fi
# 显式：若曾装过共享 zlib，无条件重建静态（本脚本开头已 rm dylib，用 stamp 缺失触发）。
if [[ ! -f "$STAMP" ]]; then
  rm -f "$PREFIX/lib/pkgconfig/zlib.pc" "$PREFIX/share/pkgconfig/zlib.pc"
fi

cflags=""
cmake_osx=()
# meson 额外参数（交叉用 cross-file；勿对空数组用 [@] + set -u）
dav1d_meson_extra=()
if [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
  # shellcheck source=scripts/kotv-win-build-env.sh
  source "$ROOT/scripts/kotv-win-build-env.sh"
  # 用真实硬件 arch：Rosetta 下 uname -m 会谎报 x86_64，导致漏写 cross-file 仍编 ARM asm。
  hw_arch="$(kotv_macos_hw_arch)"
  arch="${KOTV_MPV_MACOS_ARCH:-$hw_arch}"
  cflags="-arch $arch"
  cmake_osx=(-DCMAKE_OSX_ARCHITECTURES="$arch")
  if [[ "$arch" != "$hw_arch" ]]; then
    # Apple Silicon 编 x86_64：必须用 cross-file；native-file 改不了 host cpu_family。
    ini="$BUILD_DIR/meson-cross-dav1d-${arch}.ini"
    cpu_family="$arch"
    [[ "$arch" == "arm64" ]] && cpu_family="aarch64"
    [[ "$arch" == "x86_64" ]] && cpu_family="x86_64"
    cat >"$ini" <<EOF
[binaries]
c = ['clang', '-arch', '$arch']
cpp = ['clang++', '-arch', '$arch']
ar = 'ar'
strip = 'strip'
pkg-config = 'pkg-config'
[built-in options]
c_args = ['-arch', '$arch']
c_link_args = ['-arch', '$arch']
[host_machine]
system = 'darwin'
cpu_family = '$cpu_family'
cpu = '$arch'
endian = 'little'
EOF
    dav1d_meson_extra+=(--cross-file="$ini")
    # 交叉时关 asm 更稳（clang -arch 与汇编器目标偶发不一致）
    dav1d_meson_extra+=(-Denable_asm=false)
    echo "==> dav1d macOS cross hw=$hw_arch uname=$(uname -m) -> $arch (cross-file, asm=off)"
  fi
fi
export CFLAGS="${CFLAGS:-} $cflags"
export CXXFLAGS="${CXXFLAGS:-} $cflags"
export LDFLAGS="${LDFLAGS:-} $cflags"

src="$BUILD_DIR/src"
mkdir -p "$src" "$PREFIX/lib/pkgconfig" "$PREFIX/include" "$PREFIX/lib"

cmake_gen="Ninja"
command -v ninja >/dev/null || cmake_gen="Unix Makefiles"
if is_windows; then
  if command -v ninja >/dev/null; then
    cmake_gen="Ninja"
  else
    cmake_gen="MinGW Makefiles"
  fi
fi

echo "==> ffmpeg codecs (dav1d + libxml2 + libaribcaption) -> $PREFIX"

# --- dav1d ---
if ! pc_ready dav1d; then
  echo "==> build dav1d $DAV1D_VER ($DAV1D_SHA)"
  cd "$BUILD_DIR"
  if [[ ! -d dav1d/.git ]]; then
    git clone --filter=blob:none --branch "$DAV1D_VER" "$DAV1D_REPO" dav1d \
      || git clone --filter=blob:none "$DAV1D_REPO" dav1d
  fi
  git -C dav1d fetch --depth 1 origin "$DAV1D_SHA" 2>/dev/null \
    || git -C dav1d fetch --depth 50 origin "refs/tags/${DAV1D_VER}:refs/tags/${DAV1D_VER}" 2>/dev/null \
    || true
  git -C dav1d checkout -q "$DAV1D_SHA" 2>/dev/null \
    || git -C dav1d checkout -q "$DAV1D_VER" \
    || { echo "ERROR: cannot checkout dav1d $DAV1D_VER / $DAV1D_SHA" >&2; exit 1; }
  rm -rf dav1d/build
  meson_cmd=(meson setup dav1d/build dav1d
    --prefix="$PREFIX"
    --libdir=lib
    -Ddefault_library=static
    -Denable_tools=false
    -Denable_tests=false
    -Denable_examples=false)
  if ((${#dav1d_meson_extra[@]})); then
    meson_cmd+=("${dav1d_meson_extra[@]}")
  fi
  "${meson_cmd[@]}"
  meson compile -C dav1d/build -j "$JOBS"
  meson install -C dav1d/build
  pc_ready dav1d || { echo "ERROR: dav1d not installed under $PREFIX" >&2; ls -la "$PREFIX/lib" "$PREFIX/lib/pkgconfig" 2>/dev/null || true; exit 1; }
  echo "ok dav1d $DAV1D_VER"
else
  echo "ok dav1d (cached in PREFIX)"
fi

# --- zlib（libxml2 gzip）---
if ! pc_ready zlib; then
  echo "==> build zlib $ZLIB_VER (for libxml2)"
  fetch "https://github.com/madler/zlib/releases/download/v${ZLIB_VER}/zlib-${ZLIB_VER}.tar.gz" \
    "$src/zlib-${ZLIB_VER}.tar.gz" "$ZLIB_SHA" \
    || fetch "https://www.zlib.net/fossils/zlib-${ZLIB_VER}.tar.gz" \
      "$src/zlib-${ZLIB_VER}.tar.gz" "$ZLIB_SHA"
  rm -rf "$BUILD_DIR/zlib" "$BUILD_DIR/zlib-build"
  mkdir -p "$BUILD_DIR/zlib"
  tar -xf "$src/zlib-${ZLIB_VER}.tar.gz" -C "$BUILD_DIR/zlib" --strip-components=1
  z_cmake=(cmake -S "$BUILD_DIR/zlib" -B "$BUILD_DIR/zlib-build" -G "$cmake_gen"
    -DCMAKE_INSTALL_PREFIX="$PREFIX"
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    -DBUILD_SHARED_LIBS=OFF)
  if ((${#cmake_osx[@]})); then
    z_cmake+=("${cmake_osx[@]}")
  fi
  if [[ -n "${CFLAGS:-}" ]]; then
    z_cmake+=(-DCMAKE_C_FLAGS="$CFLAGS")
  fi
  "${z_cmake[@]}"
  # zlib 的 CMake 即使 BUILD_SHARED_LIBS=OFF 仍常编出 dylib；只装静态，避免 FFmpeg
  # configure 早期 -L$PREFIX/lib 链到坏共享库后 Abort trap。
  cmake --build "$BUILD_DIR/zlib-build" -j"$JOBS" --target zlibstatic
  mkdir -p "$PREFIX/lib" "$PREFIX/include" "$PREFIX/lib/pkgconfig"
  zstat=""
  for cand in \
    "$BUILD_DIR/zlib-build/libzlibstatic.a" \
    "$BUILD_DIR/zlib-build/zlibstatic.lib" \
    "$BUILD_DIR/zlib-build/libz.a" \
    "$BUILD_DIR/zlib-build/lib/libz.a"; do
    [[ -f "$cand" ]] && { zstat="$cand"; break; }
  done
  [[ -n "$zstat" ]] || { echo "ERROR: zlibstatic not built" >&2; ls -laR "$BUILD_DIR/zlib-build" | head -80 >&2; exit 1; }
  cp -f "$zstat" "$PREFIX/lib/libz.a"
  cp -f "$BUILD_DIR/zlib/zlib.h" "$PREFIX/include/zlib.h"
  if [[ -f "$BUILD_DIR/zlib-build/zconf.h" ]]; then
    cp -f "$BUILD_DIR/zlib-build/zconf.h" "$PREFIX/include/zconf.h"
  else
    cp -f "$BUILD_DIR/zlib/zconf.h" "$PREFIX/include/zconf.h"
  fi
  rm -f "$PREFIX/lib"/libz*.dylib "$PREFIX/lib"/libz.so* "$PREFIX/lib"/zlib.dll* \
    "$PREFIX/share/pkgconfig/zlib.pc" 2>/dev/null || true
  cat >"$PREFIX/lib/pkgconfig/zlib.pc" <<EOF
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: zlib
Description: zlib compression library
Version: $ZLIB_VER
Libs: -L\${libdir} -lz
Cflags: -I\${includedir}
EOF
  pc_ready zlib || { echo "ERROR: zlib not installed under $PREFIX" >&2; exit 1; }
  echo "ok zlib $ZLIB_VER (static)"
else
  echo "ok zlib (cached in PREFIX)"
fi

# --- liblzma / xz（libxml2 xz 压缩 XML）---
if ! pc_ready liblzma; then
  echo "==> build liblzma $XZ_VER (for libxml2)"
  fetch "https://github.com/tukaani-project/xz/releases/download/v${XZ_VER}/xz-${XZ_VER}.tar.gz" \
    "$src/xz-${XZ_VER}.tar.gz" "$XZ_SHA"
  rm -rf "$BUILD_DIR/xz" "$BUILD_DIR/xz-build"
  mkdir -p "$BUILD_DIR/xz"
  tar -xf "$src/xz-${XZ_VER}.tar.gz" -C "$BUILD_DIR/xz" --strip-components=1
  xz_cmake=(cmake -S "$BUILD_DIR/xz" -B "$BUILD_DIR/xz-build" -G "$cmake_gen"
    -DCMAKE_INSTALL_PREFIX="$PREFIX"
    -DCMAKE_INSTALL_LIBDIR=lib
    -DCMAKE_BUILD_TYPE=Release
    -DBUILD_SHARED_LIBS=OFF
    -DBUILD_TESTING=OFF
    -DXZ_TOOL_XZ=OFF
    -DXZ_TOOL_XZDEC=OFF
    -DXZ_TOOL_LZMADEC=OFF
    -DXZ_TOOL_LZMAINFO=OFF
    -DXZ_TOOL_XZDIFF=OFF
    -DXZ_TOOL_XZGREP=OFF
    -DXZ_TOOL_XZMORE=OFF
    -DXZ_TOOL_XZLESS=OFF
    -DXZ_NLS=OFF
    -DCREATE_XZ_SYMLINKS=OFF
    -DCREATE_LZMA_SYMLINKS=OFF)
  if ((${#cmake_osx[@]})); then
    xz_cmake+=("${cmake_osx[@]}")
  fi
  if [[ -n "${CFLAGS:-}" ]]; then
    xz_cmake+=(-DCMAKE_C_FLAGS="$CFLAGS")
  fi
  "${xz_cmake[@]}"
  cmake --build "$BUILD_DIR/xz-build" -j"$JOBS"
  cmake --install "$BUILD_DIR/xz-build"
  if [[ ! -f "$PREFIX/lib/pkgconfig/liblzma.pc" ]]; then
    cat >"$PREFIX/lib/pkgconfig/liblzma.pc" <<EOF
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: liblzma
Description: LZMA / XZ compression
Version: $XZ_VER
Libs: -L\${libdir} -llzma
Cflags: -I\${includedir}
EOF
  fi
  # 只要静态 liblzma；清掉共享库与 CLI，避免交叉链接 Homebrew / 污染 FFmpeg。
  rm -f "$PREFIX/lib"/liblzma*.dylib "$PREFIX/lib"/liblzma.so* \
    "$PREFIX/bin"/xz "$PREFIX/bin"/xzdec "$PREFIX/bin"/lzmadec \
    "$PREFIX/bin"/lzmainfo "$PREFIX/bin"/xzdiff "$PREFIX/bin"/xzgrep \
    "$PREFIX/bin"/xzmore "$PREFIX/bin"/xzless 2>/dev/null || true
  pc_ready liblzma || { echo "ERROR: liblzma not installed under $PREFIX" >&2; exit 1; }
  echo "ok liblzma $XZ_VER (static, tools off)"
else
  echo "ok liblzma (cached in PREFIX)"
fi

# --- libxml2（完整：zlib + lzma）---
if ! pc_ready libxml-2.0; then
  echo "==> build libxml2 $XML2_VER (zlib+lzma)"
  fetch "$XML2_URL" "$src/libxml2-${XML2_VER}.tar.gz" "$XML2_SHA"
  rm -rf "$BUILD_DIR/libxml2"
  mkdir -p "$BUILD_DIR/libxml2"
  tar -xf "$src/libxml2-${XML2_VER}.tar.gz" -C "$BUILD_DIR/libxml2" --strip-components=1
  (
    cd "$BUILD_DIR/libxml2"
    rm -rf build
    xml_cmake=(cmake -S . -B build -G "$cmake_gen"
      -DCMAKE_BUILD_TYPE=Release
      -DCMAKE_INSTALL_PREFIX="$PREFIX"
      -DCMAKE_INSTALL_LIBDIR=lib
      -DCMAKE_PREFIX_PATH="$PREFIX"
      -DBUILD_SHARED_LIBS=OFF
      -DLIBXML2_WITH_PYTHON=OFF
      -DLIBXML2_WITH_ICONV=OFF
      -DLIBXML2_WITH_ZLIB=ON
      -DLIBXML2_WITH_LZMA=ON
      -DLIBXML2_WITH_PROGRAMS=OFF
      -DLIBXML2_WITH_TESTS=OFF
      -DLIBXML2_WITH_MODULES=OFF)
    if ((${#cmake_osx[@]})); then
      xml_cmake+=("${cmake_osx[@]}")
    fi
    if [[ -n "${CFLAGS:-}" ]]; then
      xml_cmake+=(-DCMAKE_C_FLAGS="$CFLAGS")
    fi
    "${xml_cmake[@]}"
    cmake --build build -j"$JOBS"
    cmake --install build
  )
  pc_ready libxml-2.0 || { echo "ERROR: libxml2 not installed under $PREFIX" >&2; exit 1; }
  # 把 -lz/-llzma 写进 Libs（勿只靠 Requires.private），Windows/FFmpeg 探测才能链上。
  # 双 -I：FongMi 探测头 libxml2/libxml/... + 源码 libxml/...。
  cat >"$PREFIX/lib/pkgconfig/libxml-2.0.pc" <<EOF
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: libXML
Description: libxml2 (KOTV static, zlib+lzma)
Version: $XML2_VER
Requires.private: zlib liblzma
Libs: -L\${libdir} -lxml2 -lz -llzma
Cflags: -I\${includedir} -I\${includedir}/libxml2
EOF
  echo "ok libxml2 $XML2_VER (zlib+lzma)"
else
  echo "ok libxml2 (cached in PREFIX)"
fi

# --- libaribcaption ---
if ! pc_ready libaribcaption; then
  echo "==> build libaribcaption $ARIB_VER"
  fetch "$ARIB_URL" "$src/libaribcaption-${ARIB_VER}.tar.gz" "$ARIB_SHA"
  rm -rf "$BUILD_DIR/libaribcaption"
  mkdir -p "$BUILD_DIR/libaribcaption"
  tar -xf "$src/libaribcaption-${ARIB_VER}.tar.gz" -C "$BUILD_DIR/libaribcaption" --strip-components=1
  arib_extra=()
  if is_windows; then
    arib_extra+=(-DARIBCC_USE_DIRECTWRITE=ON -DARIBCC_USE_CORETEXT=OFF -DARIBCC_USE_FREETYPE=OFF -DARIBCC_USE_FONTCONFIG=OFF)
  elif [[ "$(uname -s)" == "Darwin" ]]; then
    arib_extra+=(-DARIBCC_USE_CORETEXT=ON -DARIBCC_USE_DIRECTWRITE=OFF -DARIBCC_USE_FREETYPE=OFF -DARIBCC_USE_FONTCONFIG=OFF)
  else
    # Linux auto FontProvider 需要 Fontconfig；FreeType 仍用嵌入式。
    arib_extra+=(-DARIBCC_USE_FREETYPE=ON -DARIBCC_USE_EMBEDDED_FREETYPE=ON -DARIBCC_USE_FONTCONFIG=ON -DARIBCC_USE_CORETEXT=OFF -DARIBCC_USE_DIRECTWRITE=OFF)
  fi
  (
    cd "$BUILD_DIR/libaribcaption"
    rm -rf build
    arib_cmake=(cmake -S . -B build -G "$cmake_gen"
      -DCMAKE_BUILD_TYPE=Release
      -DCMAKE_INSTALL_PREFIX="$PREFIX"
      -DCMAKE_INSTALL_LIBDIR=lib
      -DBUILD_SHARED_LIBS=OFF
      -DARIBCC_SHARED_LIBRARY=OFF
      -DARIBCC_BUILD_TESTS=OFF
      "${arib_extra[@]}")
    if ((${#cmake_osx[@]})); then
      arib_cmake+=("${cmake_osx[@]}")
    fi
    if [[ -n "${CFLAGS:-}" ]]; then
      arib_cmake+=(-DCMAKE_C_FLAGS="$CFLAGS")
    fi
    if [[ -n "${CXXFLAGS:-}" ]]; then
      arib_cmake+=(-DCMAKE_CXX_FLAGS="$CXXFLAGS")
    fi
    "${arib_cmake[@]}"
    cmake --build build -j"$JOBS"
    cmake --install build
  )
  if [[ ! -f "$PREFIX/lib/pkgconfig/libaribcaption.pc" ]] || is_windows; then
    # Windows：FFmpeg require_pkg_config 链接探测需要 C++/DirectWrite。
    private_libs=""
    if is_windows; then
      private_libs=" -lstdc++ -ldwrite -lole32 -luuid"
    elif [[ "$(uname -s)" != "Darwin" ]]; then
      private_libs=" -lstdc++ -lfontconfig -lfreetype"
    else
      private_libs=" -lc++ -framework CoreText -framework CoreFoundation"
    fi
    cat >"$PREFIX/lib/pkgconfig/libaribcaption.pc" <<EOF
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: libaribcaption
Description: ARIB STD-B24 caption decoder
Version: $ARIB_VER
Libs: -L\${libdir} -laribcaption
Libs.private:${private_libs}
Cflags: -I\${includedir}
EOF
  fi
  pc_ready libaribcaption || { echo "ERROR: libaribcaption not installed under $PREFIX" >&2; exit 1; }
  echo "ok libaribcaption $ARIB_VER"
else
  echo "ok libaribcaption (cached in PREFIX)"
fi

printf '%s\n' "dav1d=${DAV1D_VER} zlib=${ZLIB_VER} lzma=${XZ_VER} xml2=${XML2_VER} arib=${ARIB_VER}" >"$STAMP"
echo "ok ffmpeg codecs ready"
