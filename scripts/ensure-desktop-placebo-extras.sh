#!/usr/bin/env bash
# libplacebo 可选依赖：lcms2（ICC）+ xxhash（更快哈希）。静态装进 PREFIX。
# glslang 不装：已有 shaderc 时官方更推荐 shaderc，双开多余且易踩坑。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${KOTV_MPV_BUILD_DIR:-$ROOT/.build/desktop-mpv}"
PREFIX="${KOTV_DESKTOP_FFMPEG_PREFIX:-$BUILD_DIR/prefix}"
STAMP="$PREFIX/.kotv-placebo-extras-v1"
JOBS="${KOTV_MPV_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "${NUMBER_OF_PROCESSORS:-4}")}"

LCMS_VER=2.16
LCMS_SHA=d873d34ad8b9b4cea010631f1a6228d2087475e4dc5e763eb81acc23d9d45a51
XXHASH_VER=0.8.3
XXHASH_SHA=aae608dfe8213dfd05d909a57718ef82f30722c392344583d3f39050c7f29a80

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
need cmake
need make

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
if is_windows || [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
  export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
fi

if [[ -f "$STAMP" ]] && pkg-config --exists lcms2 2>/dev/null && pkg-config --exists libxxhash 2>/dev/null; then
  echo "ok cached placebo extras (lcms2=$(pkg-config --modversion lcms2) xxhash=$(pkg-config --modversion libxxhash))"
  exit 0
fi

cflags=""
if [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
  arch="${KOTV_MPV_MACOS_ARCH:-$(uname -m)}"
  cflags="-arch $arch"
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

echo "==> placebo extras (lcms2 + xxhash) -> $PREFIX"

# --- lcms2 ---
if ! pkg-config --exists lcms2 2>/dev/null || [[ ! -f "$PREFIX/lib/liblcms2.a" && ! -f "$PREFIX/lib/liblcms2.dll.a" ]]; then
  # Linux 可用系统 lcms2；若 PREFIX 未装且系统有，也接受（不强制自编）。
  if ! is_windows && [[ "$(uname -s)" != "Darwin" ]] && pkg-config --exists lcms2 2>/dev/null; then
    echo "ok lcms2 $(pkg-config --modversion lcms2) (system)"
  else
    fetch "https://github.com/mm2/Little-CMS/releases/download/lcms2.${LCMS_VER#2.}/lcms2-${LCMS_VER}.tar.gz" \
      "$src/lcms2-${LCMS_VER}.tar.gz" "$LCMS_SHA" \
      || fetch "https://sourceforge.net/projects/lcms/files/lcms/${LCMS_VER}/lcms2-${LCMS_VER}.tar.gz/download" \
        "$src/lcms2-${LCMS_VER}.tar.gz" "$LCMS_SHA"
    rm -rf "$BUILD_DIR/lcms2"
    mkdir -p "$BUILD_DIR/lcms2"
    tar -xf "$src/lcms2-${LCMS_VER}.tar.gz" -C "$BUILD_DIR/lcms2" --strip-components=1
    (
      cd "$BUILD_DIR/lcms2"
      if [[ -f meson.build ]] && command -v meson >/dev/null; then
        rm -rf build
        meson setup build --prefix="$PREFIX" --libdir=lib \
          -Ddefault_library=static -Dutils=false -Dsamples=false -Dfastfloat=false -Dthreaded=false \
          -Djpeg=disabled -Dtiff=disabled
        meson compile -C build -j "$JOBS"
        meson install -C build
      else
        ./configure --prefix="$PREFIX" --disable-shared --enable-static --without-jpeg --without-tiff
        make -j"$JOBS"
        make install
      fi
    )
    pkg-config --exists lcms2 || { echo "ERROR: lcms2.pc missing" >&2; exit 1; }
    echo "ok lcms2 $LCMS_VER (PREFIX)"
  fi
else
  echo "ok lcms2 $(pkg-config --modversion lcms2) (PREFIX)"
fi

# --- xxhash ---
if ! pkg-config --exists libxxhash 2>/dev/null || [[ ! -f "$PREFIX/lib/libxxhash.a" && ! -f "$PREFIX/lib/libxxhash.dll.a" ]]; then
  if ! is_windows && [[ "$(uname -s)" != "Darwin" ]] && pkg-config --exists libxxhash 2>/dev/null; then
    echo "ok xxhash $(pkg-config --modversion libxxhash) (system)"
  else
    fetch "https://github.com/Cyan4973/xxHash/archive/refs/tags/v${XXHASH_VER}.tar.gz" \
      "$src/xxhash-${XXHASH_VER}.tar.gz" "$XXHASH_SHA"
    rm -rf "$BUILD_DIR/xxhash"
    mkdir -p "$BUILD_DIR/xxhash"
    tar -xf "$src/xxhash-${XXHASH_VER}.tar.gz" -C "$BUILD_DIR/xxhash" --strip-components=1
    (
      cd "$BUILD_DIR/xxhash"
      rm -rf build
      cmake -S cmake_unofficial -B build -G "$cmake_gen" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DBUILD_SHARED_LIBS=OFF \
        -DXXHASH_BUILD_XXHSUM=OFF \
        ${CFLAGS:+-DCMAKE_C_FLAGS="$CFLAGS"}
      cmake --build build -j"$JOBS"
      cmake --install build
    )
    # 个别 cmake 版本只装头文件+库、不写 .pc
    if [[ ! -f "$PREFIX/lib/pkgconfig/libxxhash.pc" ]]; then
      cat >"$PREFIX/lib/pkgconfig/libxxhash.pc" <<EOF
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: xxhash
Description: extremely fast hash algorithm
Version: $XXHASH_VER
Libs: -L\${libdir} -lxxhash
Cflags: -I\${includedir}
EOF
    fi
    pkg-config --exists libxxhash || { echo "ERROR: libxxhash.pc missing" >&2; exit 1; }
    echo "ok xxhash $XXHASH_VER (PREFIX)"
  fi
else
  echo "ok xxhash $(pkg-config --modversion libxxhash) (PREFIX)"
fi

printf '%s\n' "lcms2=${LCMS_VER} xxhash=${XXHASH_VER}" >"$STAMP"
echo "ok placebo extras ready"
