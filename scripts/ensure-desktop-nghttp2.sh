#!/usr/bin/env bash
# 把静态 libnghttp2 装进 PREFIX，供 FFmpeg --enable-libnghttp2（HTTP/2）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${KOTV_MPV_BUILD_DIR:-$ROOT/.build/desktop-mpv}"
PREFIX="${KOTV_DESKTOP_FFMPEG_PREFIX:-$BUILD_DIR/prefix}"
JOBS="${KOTV_MPV_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "${NUMBER_OF_PROCESSORS:-4}")}"
NGHTTP2_VER="${KOTV_NGHTTP2_VER:-1.64.0}"

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

mkdir -p "$PREFIX/lib/pkgconfig" "$PREFIX/include" "$PREFIX/lib" "$BUILD_DIR"
export PKG_CONFIG_PATH="$(kotv_native_path "$PREFIX/lib/pkgconfig")${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

if pkg-config --exists libnghttp2 2>/dev/null && [[ -f "$PREFIX/lib/libnghttp2.a" || -f "$PREFIX/lib/libnghttp2.dll.a" ]]; then
  echo "ok cached libnghttp2 $(pkg-config --modversion libnghttp2)"
  exit 0
fi
# 系统已有（Linux apt / brew）也可：拷一份 .pc 指针不够，FFmpeg 要能链到；优先 PREFIX 静态。
if ! kotv_is_windows_build && pkg-config --exists libnghttp2 2>/dev/null; then
  echo "ok system libnghttp2 $(pkg-config --modversion libnghttp2) (will let FFmpeg use PKG_CONFIG_PATH)"
  # 仍尽量编进 PREFIX，避免 meson/FFmpeg 只认 PREFIX。
fi

need() { command -v "$1" >/dev/null || { echo "need $1" >&2; exit 1; }; }
need cmake
need curl
need tar

src="$BUILD_DIR/nghttp2-$NGHTTP2_VER"
tarball="$BUILD_DIR/nghttp2-$NGHTTP2_VER.tar.gz"
if [[ ! -f "$src/CMakeLists.txt" ]]; then
  curl -fsSL -o "$tarball" \
    "https://github.com/nghttp2/nghttp2/releases/download/v${NGHTTP2_VER}/nghttp2-${NGHTTP2_VER}.tar.gz"
  rm -rf "$src"
  tar -xzf "$tarball" -C "$BUILD_DIR"
fi

pref="$(kotv_native_path "$PREFIX")"
build="$BUILD_DIR/nghttp2-build"
rm -rf "$build"
mkdir -p "$build"

gen=Ninja
command -v ninja >/dev/null 2>&1 || gen="Unix Makefiles"
if kotv_is_windows_build; then
  gen="MinGW Makefiles"
  export PATH="/c/mingw-msvcrt/mingw64/bin:/usr/bin:/bin:${PATH:-}"
  cleaned=""
  IFS=':' read -ra _p <<<"$PATH"
  for part in "${_p[@]}"; do
    case "$part" in *[\ ]*|*[Pp]rogram*[Ff]iles*) continue ;; esac
    [[ -z "$cleaned" ]] && cleaned="$part" || cleaned="$cleaned:$part"
  done
  export PATH="$cleaned"
  export CC=gcc CXX=g++
  export CFLAGS="${CFLAGS:-} -D_WIN32_WINNT=0x0601 -DWINVER=0x0601 -DNTDDI_VERSION=0x06010000"
fi

echo "==> build libnghttp2 $NGHTTP2_VER → $pref (generator=$gen)"
nghttp2_cmake=(
  -DCMAKE_INSTALL_PREFIX="$pref"
  -DCMAKE_BUILD_TYPE=Release
  -DENABLE_LIB_ONLY=ON
  -DENABLE_STATIC_LIB=ON
  -DENABLE_SHARED_LIB=OFF
  -DBUILD_SHARED_LIBS=OFF
  -DENABLE_APP=OFF
  -DENABLE_DOC=OFF
  -DENABLE_EXAMPLES=OFF
  -DBUILD_TESTING=OFF
)
if kotv_is_windows_build; then
  nghttp2_cmake+=(-DCMAKE_C_FLAGS="-D_WIN32_WINNT=0x0601 -DWINVER=0x0601 -DNTDDI_VERSION=0x06010000")
fi
cmake -S "$src" -B "$build" -G "$gen" "${nghttp2_cmake[@]}"
cmake --build "$build" -j"$JOBS"
cmake --install "$build"

# 统一静态库名
if [[ -f "$PREFIX/lib/libnghttp2_static.a" && ! -f "$PREFIX/lib/libnghttp2.a" ]]; then
  cp -f "$PREFIX/lib/libnghttp2_static.a" "$PREFIX/lib/libnghttp2.a"
fi
# 部分版本 pc 名叫 libnghttp2.pc
if [[ ! -f "$PREFIX/lib/pkgconfig/libnghttp2.pc" ]]; then
  cat >"$PREFIX/lib/pkgconfig/libnghttp2.pc" <<EOF
prefix=$pref
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: libnghttp2
Description: HTTP/2 C library
Version: $NGHTTP2_VER
Libs: -L\${libdir} -lnghttp2
Cflags: -I\${includedir}
EOF
fi

pkg-config --exists libnghttp2 || { echo "ERROR: libnghttp2.pc missing" >&2; exit 1; }
echo "ok libnghttp2 $(pkg-config --modversion libnghttp2)"
