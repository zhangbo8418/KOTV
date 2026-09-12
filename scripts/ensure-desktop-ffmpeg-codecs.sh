#!/usr/bin/env bash
# 桌面 FFmpeg 外部解码库：dav1d（AV1）+ libxml2 + libaribcaption（日标字幕）。
# 静态装进 PREFIX，与安卓 webhtv 锁的版本对齐。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${KOTV_MPV_BUILD_DIR:-$ROOT/.build/desktop-mpv}"
PREFIX="${KOTV_DESKTOP_FFMPEG_PREFIX:-$BUILD_DIR/prefix}"
STAMP="$PREFIX/.kotv-ffmpeg-codecs-v1"
JOBS="${KOTV_MPV_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "${NUMBER_OF_PROCESSORS:-4}")}"

DAV1D_VER=1.5.4
DAV1D_SHA=54706fc6bc0cdecab7e9593974a4039cc038fca7
DAV1D_REPO=https://github.com/videolan/dav1d.git

XML2_VER=2.15.3
XML2_URL="https://gitlab.gnome.org/GNOME/libxml2/-/archive/v${XML2_VER}/libxml2-v${XML2_VER}.tar.gz"
XML2_SHA=0da50c1415f4ec0364569d2119b1436ba837b31df44af28569d234272c23cf1f

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
need pkg-config

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
if is_windows || [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
  export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
fi

if [[ -f "$STAMP" ]] \
  && pkg-config --exists dav1d 2>/dev/null \
  && pkg-config --exists libxml-2.0 2>/dev/null \
  && pkg-config --exists libaribcaption 2>/dev/null; then
  echo "ok cached ffmpeg codecs (dav1d=$(pkg-config --modversion dav1d) xml2=$(pkg-config --modversion libxml-2.0) arib=$(pkg-config --modversion libaribcaption))"
  exit 0
fi

cflags=""
cmake_osx=()
meson_native=()
if [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
  arch="${KOTV_MPV_MACOS_ARCH:-$(uname -m)}"
  cflags="-arch $arch"
  cmake_osx=(-DCMAKE_OSX_ARCHITECTURES="$arch")
  # dav1d meson：交叉 arch 时写 native-file
  if [[ "$arch" != "$(uname -m)" ]] || [[ -n "${KOTV_MPV_MACOS_ARCH:-}" ]]; then
    ini="$BUILD_DIR/meson-native-dav1d-${arch}.ini"
    cpu_family="$arch"
    [[ "$arch" == "arm64" ]] && cpu_family="aarch64"
    cat >"$ini" <<EOF
[binaries]
c = ['clang', '-arch', '$arch']
cpp = ['clang++', '-arch', '$arch']
ar = 'ar'
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
    meson_native=(--native-file="$ini")
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
if ! pkg-config --exists dav1d 2>/dev/null || [[ ! -f "$PREFIX/lib/libdav1d.a" && ! -f "$PREFIX/lib/libdav1d.dll.a" ]]; then
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
  meson setup dav1d/build dav1d \
    --prefix="$PREFIX" \
    --libdir=lib \
    "${meson_native[@]}" \
    -Ddefault_library=static \
    -Denable_tools=false \
    -Denable_tests=false \
    -Denable_examples=false
  meson compile -C dav1d/build -j "$JOBS"
  meson install -C dav1d/build
  pkg-config --exists dav1d || { echo "ERROR: dav1d.pc missing" >&2; exit 1; }
  echo "ok dav1d $(pkg-config --modversion dav1d)"
else
  echo "ok dav1d $(pkg-config --modversion dav1d) (cached)"
fi

# --- libxml2 ---
if ! pkg-config --exists libxml-2.0 2>/dev/null || [[ ! -f "$PREFIX/lib/libxml2.a" && ! -f "$PREFIX/lib/libxml2.dll.a" ]]; then
  echo "==> build libxml2 $XML2_VER"
  fetch "$XML2_URL" "$src/libxml2-${XML2_VER}.tar.gz" "$XML2_SHA"
  rm -rf "$BUILD_DIR/libxml2"
  mkdir -p "$BUILD_DIR/libxml2"
  tar -xf "$src/libxml2-${XML2_VER}.tar.gz" -C "$BUILD_DIR/libxml2" --strip-components=1
  (
    cd "$BUILD_DIR/libxml2"
    rm -rf build
    cmake -S . -B build -G "$cmake_gen" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="$PREFIX" \
      -DCMAKE_INSTALL_LIBDIR=lib \
      "${cmake_osx[@]}" \
      -DBUILD_SHARED_LIBS=OFF \
      -DLIBXML2_WITH_PYTHON=OFF \
      -DLIBXML2_WITH_ICONV=OFF \
      -DLIBXML2_WITH_PROGRAMS=OFF \
      -DLIBXML2_WITH_TESTS=OFF \
      -DLIBXML2_WITH_MODULES=OFF \
      ${CFLAGS:+-DCMAKE_C_FLAGS="$CFLAGS"}
    cmake --build build -j"$JOBS"
    cmake --install build
  )
  pkg-config --exists libxml-2.0 || { echo "ERROR: libxml-2.0.pc missing" >&2; exit 1; }
  echo "ok libxml2 $(pkg-config --modversion libxml-2.0)"
else
  echo "ok libxml2 $(pkg-config --modversion libxml-2.0) (cached)"
fi

# --- libaribcaption ---
if ! pkg-config --exists libaribcaption 2>/dev/null || [[ ! -f "$PREFIX/lib/libaribcaption.a" && ! -f "$PREFIX/lib/libaribcaption.dll.a" ]]; then
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
    # Linux：嵌入 FreeType，不依赖系统 fontconfig（PREFIX 锁包时更稳）。
    arib_extra+=(-DARIBCC_USE_FREETYPE=ON -DARIBCC_USE_EMBEDDED_FREETYPE=ON -DARIBCC_USE_FONTCONFIG=OFF -DARIBCC_USE_CORETEXT=OFF -DARIBCC_USE_DIRECTWRITE=OFF)
  fi
  (
    cd "$BUILD_DIR/libaribcaption"
    rm -rf build
    cmake -S . -B build -G "$cmake_gen" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="$PREFIX" \
      -DCMAKE_INSTALL_LIBDIR=lib \
      "${cmake_osx[@]}" \
      -DBUILD_SHARED_LIBS=OFF \
      -DARIBCC_SHARED_LIBRARY=OFF \
      -DARIBCC_BUILD_TESTS=OFF \
      "${arib_extra[@]}" \
      ${CFLAGS:+-DCMAKE_C_FLAGS="$CFLAGS"} \
      ${CXXFLAGS:+-DCMAKE_CXX_FLAGS="$CXXFLAGS"}
    cmake --build build -j"$JOBS"
    cmake --install build
  )
  # 个别安装不写 .pc
  if [[ ! -f "$PREFIX/lib/pkgconfig/libaribcaption.pc" ]]; then
    cat >"$PREFIX/lib/pkgconfig/libaribcaption.pc" <<EOF
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: libaribcaption
Description: ARIB STD-B24 caption decoder
Version: $ARIB_VER
Libs: -L\${libdir} -laribcaption
Cflags: -I\${includedir}
EOF
  fi
  pkg-config --exists libaribcaption || { echo "ERROR: libaribcaption.pc missing" >&2; exit 1; }
  echo "ok libaribcaption $(pkg-config --modversion libaribcaption)"
else
  echo "ok libaribcaption $(pkg-config --modversion libaribcaption) (cached)"
fi

printf '%s\n' "dav1d=${DAV1D_VER} xml2=${XML2_VER} arib=${ARIB_VER}" >"$STAMP"
echo "ok ffmpeg codecs ready"
