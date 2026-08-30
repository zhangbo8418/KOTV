#!/usr/bin/env bash
# 桌面 FFmpeg 前缀：FongMi FFmpeg 9 + dependency/avs3a（libarcdav3a / AV3A，对齐 TV/webhtv）。
# 支持 Linux / macOS / Windows(GitHub Actions MinGW)。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${KOTV_MPV_BUILD_DIR:-$ROOT/.build/desktop-mpv}"
PREFIX="${KOTV_DESKTOP_FFMPEG_PREFIX:-$BUILD_DIR/prefix}"
FFMPEG_REPO="${KOTV_FFMPEG_REPO:-https://github.com/FongMi/FFmpeg.git}"
FFMPEG_COMMIT="${KOTV_FFMPEG_COMMIT:-04482c8d13ac27b2a9fe93f5d388929eef8af5f4}"
JOBS="${KOTV_MPV_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "${NUMBER_OF_PROCESSORS:-4}")}"
PKG_BIN="$BUILD_DIR/bin"

kotv_is_windows_build() {
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
  esac
  [[ "${OS:-}" == "Windows_NT" ]]
}

# gcc / FFmpeg 在 Windows 上更吃 D:/ 路径；MSYS 绝对路径 /d/ 偶发链接探测失败。
kotv_native_path() {
  local p="$1"
  if kotv_is_windows_build && command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$p"
  else
    printf '%s' "$p"
  fi
}

if kotv_is_windows_build; then
  if [[ -d "/c/mingw-msvcrt/mingw64/bin" ]]; then
    export PATH="/c/mingw-msvcrt/mingw64/bin:$PATH"
  fi
  export PATH="/c/Program Files/NASM:/c/ProgramData/chocolatey/bin:$PATH"
  # 避开坏掉的 Strawberry Perl pkg-config，优先 Git/MSYS 与我们的包装器
  export PATH="/usr/bin:$PATH"
  MAKE="${KOTV_MAKE:-mingw32-make}"
  CMAKE_GENERATOR="${KOTV_CMAKE_GENERATOR:-MinGW Makefiles}"
else
  MAKE="${KOTV_MAKE:-make}"
  CMAKE_GENERATOR="${KOTV_CMAKE_GENERATOR:-Unix Makefiles}"
fi

need() { command -v "$1" >/dev/null || { echo "need $1" >&2; exit 1; }; }
need git
need cmake
command -v "$MAKE" >/dev/null || need make

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

clone_ffmpeg() {
  if [[ -d ffmpeg/.git ]]; then
    git -C ffmpeg fetch --depth 1 origin "$FFMPEG_COMMIT" 2>/dev/null || true
    git -C ffmpeg checkout -q "$FFMPEG_COMMIT"
    return
  fi
  git clone --filter=blob:none --depth 1 "$FFMPEG_REPO" ffmpeg
  git -C ffmpeg fetch --depth 1 origin "$FFMPEG_COMMIT"
  git -C ffmpeg checkout -q "$FFMPEG_COMMIT"
}

# v2: libarcdav3a 必须 -fPIC（链进 libmpv.so）
STAMP_FILE="$PREFIX/.kotv-ffmpeg-av3a-v2"

marker_ok() {
  [[ -f "$STAMP_FILE" ]] || return 1
  [[ -f "$PREFIX/lib/libavcodec.a" ]] \
    || [[ -f "$PREFIX/lib/libavcodec.dll.a" ]] \
    || [[ -f "$PREFIX/lib/libavcodec.dylib" ]] \
    || [[ -f "$PREFIX/lib/libavcodec.so" ]]
}

av3a_in_prefix() {
  local lib="$PREFIX/lib/libavcodec.a"
  [[ -f "$lib" ]] || lib="$PREFIX/lib/libavcodec.dll.a"
  [[ -f "$lib" ]] || return 1
  grep -aqE 'libarcdav3a|AV3A Audio Vivid' "$lib" 2>/dev/null
}

write_arcdav3a_pc() {
  local pc="$PREFIX/lib/pkgconfig/arcdav3a.pc"
  local pref
  pref="$(kotv_native_path "$PREFIX")"
  mkdir -p "$PREFIX/lib/pkgconfig"
  cat >"$pc" <<EOF
prefix=$pref
exec_prefix=$pref
libdir=$pref/lib
includedir=$pref/include

Name: arcdav3a
Description: AVS3-P3 / AV3A decoder (libarcdav3a)
Version: 1.0.0
Libs: -L$pref/lib -larcdav3a -lm
Cflags: -I$pref/include
EOF
}

# 自包含 pkg-config：读 PREFIX/.pc；Windows 另写 .cmd 供 meson(Python) 找到。
install_pkg_config_wrapper() {
  local py_src="$ROOT/scripts/kotv-pkg-config.py"
  [[ -f "$py_src" ]] || { echo "ERROR: missing $py_src" >&2; exit 1; }
  mkdir -p "$PKG_BIN"
  cp -f "$py_src" "$PKG_BIN/kotv-pkg-config.py"
  cat >"$PKG_BIN/pkg-config" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
export PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-}"
if command -v python3 >/dev/null 2>&1; then
  exec python3 "$here/kotv-pkg-config.py" "$@"
fi
exec python "$here/kotv-pkg-config.py" "$@"
EOF
  chmod +x "$PKG_BIN/pkg-config"
  # Windows meson 只认 .bat/.cmd/.exe，不会跑无扩展名的 bash 脚本
  cat >"$PKG_BIN/pkg-config.cmd" <<'EOF'
@echo off
setlocal
set "HERE=%~dp0"
python "%HERE%kotv-pkg-config.py" %*
exit /b %ERRORLEVEL%
EOF
  # 去掉 PATH 里的 Strawberry，避免 meson 优先撞上坏掉的 pkg-config.bat
  local cleaned="" part
  IFS=':' read -ra _path_parts <<<"$PATH"
  for part in "${_path_parts[@]}"; do
    case "$part" in
      *[Ss]trawberry*) continue ;;
    esac
    if [[ -z "$cleaned" ]]; then
      cleaned="$part"
    else
      cleaned="$cleaned:$part"
    fi
  done
  export PATH="$PKG_BIN:$cleaned"
  export PKG_CONFIG="$PKG_BIN/pkg-config"
  export PKG_CONFIG_PATH="$(kotv_native_path "$PREFIX/lib/pkgconfig")${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  echo "ok pkg-config wrapper → $PKG_BIN (PKG_CONFIG_PATH=$PKG_CONFIG_PATH)"
  "$PKG_CONFIG" --exists arcdav3a
  echo "  cflags=$("$PKG_CONFIG" --cflags arcdav3a)"
  echo "  libs=$("$PKG_CONFIG" --libs arcdav3a)"
}

setup_pkg_config() {
  write_arcdav3a_pc
  export PKG_CONFIG_PATH="$(kotv_native_path "$PREFIX/lib/pkgconfig")${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  if kotv_is_windows_build; then
    install_pkg_config_wrapper
    return
  fi
  need pkg-config
  if ! pkg-config --exists arcdav3a; then
    echo "ERROR: pkg-config cannot see arcdav3a (PKG_CONFIG_PATH=$PKG_CONFIG_PATH)" >&2
    cat "$PREFIX/lib/pkgconfig/arcdav3a.pc" >&2 || true
    exit 1
  fi
  echo "ok pkg-config arcdav3a: $(pkg-config --modversion arcdav3a)"
  echo "  cflags=$(pkg-config --cflags arcdav3a)"
  echo "  libs=$(pkg-config --libs arcdav3a)"
}

if marker_ok && av3a_in_prefix; then
  echo "ok cached FFmpeg+AV3A prefix: $PREFIX"
  # 缓存命中也要装好 pkg-config，供后续 meson 使用（PATH 在子进程，由 mpv 脚本再装一次）
  write_arcdav3a_pc
  if kotv_is_windows_build; then
    install_pkg_config_wrapper
  fi
  exit 0
fi

echo "==> build desktop FFmpeg+AV3A prefix → $PREFIX ($(uname -s))"
clone_ffmpeg

[[ -f ffmpeg/dependency/avs3a/CMakeLists.txt ]] \
  || { echo "ERROR: missing ffmpeg/dependency/avs3a (wrong FongMi/FFmpeg commit?)" >&2; exit 1; }
grep -q -- '--enable-libarcdav3a' ffmpeg/configure \
  || { echo "ERROR: FongMi FFmpeg lacks --enable-libarcdav3a" >&2; exit 1; }

echo "==> cmake arcdav3a (libarcdav3a, PIC) generator=$CMAKE_GENERATOR"
rm -rf arcdav3a-build
ARCD_CMAKE_ARGS=(
  -DCMAKE_INSTALL_PREFIX="$PREFIX"
  -DCMAKE_BUILD_TYPE=Release
  -DBUILD_SHARED_LIBS=OFF
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON
)
if ! kotv_is_windows_build; then
  ARCD_CMAKE_ARGS+=(-DCMAKE_C_FLAGS="-fPIC" -DCMAKE_CXX_FLAGS="-fPIC")
fi
cmake -G "$CMAKE_GENERATOR" -S ffmpeg/dependency/avs3a -B arcdav3a-build \
  "${ARCD_CMAKE_ARGS[@]}"
cmake --build arcdav3a-build -j"$JOBS"
cmake --install arcdav3a-build

[[ -f "$PREFIX/lib/libarcdav3a.a" ]] \
  || { echo "ERROR: missing $PREFIX/lib/libarcdav3a.a" >&2; exit 1; }
[[ -f "$PREFIX/include/decoder.h" ]] \
  || { echo "ERROR: missing $PREFIX/include/decoder.h" >&2; exit 1; }

setup_pkg_config

echo "==> configure FongMi FFmpeg (static PIC + libarcdav3a)"
cd ffmpeg
$MAKE distclean 2>/dev/null || true

PREF_NATIVE="$(kotv_native_path "$PREFIX")"

# Windows MinGW：pkg-config 的编译链接探测经常误报；直接 enable + 注入路径。
if kotv_is_windows_build; then
  echo "==> Windows: bypass arcdav3a pkg-config link probe"
  # 先自测一次，失败则打出真实 gcc 错误
  cat >"$BUILD_DIR/avs3_link_probe.c" <<'PROBE'
#include <decoder.h>
#include <stdint.h>
long check_avs3_create_decoder(void) { return (long)(intptr_t)avs3_create_decoder; }
int main(void) { return check_avs3_create_decoder() ? 0 : 1; }
PROBE
  if ! gcc -O0 -I"${PREF_NATIVE}/include" -L"${PREF_NATIVE}/lib" \
      -o "$BUILD_DIR/avs3_link_probe.exe" "$BUILD_DIR/avs3_link_probe.c" \
      -larcdav3a -lm 2>"$BUILD_DIR/avs3_link_probe.log"; then
    echo "ERROR: MinGW cannot link libarcdav3a:" >&2
    cat "$BUILD_DIR/avs3_link_probe.log" >&2
    exit 1
  fi
  echo "ok MinGW link probe for avs3_create_decoder"
  # require_pkg_config → 强制 enable（跳过 check_func_headers）
  # FFmpeg configure 里 add_cflags/add_extralibs 吃空格分隔参数，路径不要加引号。
  cfg_line="enabled libarcdav3a       \&\& enable libarcdav3a \&\& add_cflags -I${PREF_NATIVE}/include \&\& add_extralibs -L${PREF_NATIVE}/lib -larcdav3a -lm"
  if command -v perl >/dev/null 2>&1; then
    perl -i.bak -pe "s#enabled libarcdav3a\\s+&& require_pkg_config libarcdav3a arcdav3a decoder\\.h avs3_create_decoder#${cfg_line}#" configure
  else
    sed -i.bak "s#require_pkg_config libarcdav3a arcdav3a decoder.h avs3_create_decoder#enable libarcdav3a \&\& add_cflags -I${PREF_NATIVE}/include \&\& add_extralibs -L${PREF_NATIVE}/lib -larcdav3a -lm#" configure
  fi
  grep -n 'libarcdav3a' configure | head -8
fi

FFMPEG_EXTRA=(--extra-cflags="-I${PREF_NATIVE}/include")
FFMPEG_EXTRA+=(--extra-ldflags="-L${PREF_NATIVE}/lib")
FFMPEG_EXTRA+=(--extra-libs="-larcdav3a -lm")
if kotv_is_windows_build; then
  FFMPEG_EXTRA+=(--target-os=mingw64 --arch=x86_64)
  FFMPEG_EXTRA+=(--pkg-config="$PKG_BIN/pkg-config")
fi

if ! ./configure \
  --prefix="$PREFIX" \
  --enable-static \
  --disable-shared \
  --enable-pic \
  --enable-gpl \
  --enable-version3 \
  --enable-libarcdav3a \
  --disable-programs \
  --disable-doc \
  --disable-debug \
  "${FFMPEG_EXTRA[@]}" \
  ${KOTV_FFMPEG_CONFIGURE_EXTRA:-}; then
  echo "ERROR: FFmpeg configure failed; last 80 lines of ffbuild/config.log:" >&2
  tail -80 ffbuild/config.log 2>/dev/null >&2 || true
  exit 1
fi

$MAKE -j"$JOBS"
$MAKE install

lib="$PREFIX/lib/libavcodec.a"
[[ -f "$lib" ]] || lib="$PREFIX/lib/libavcodec.dll.a"
if ! grep -aqE 'libarcdav3a|AV3A Audio Vivid' "$lib" 2>/dev/null; then
  echo "ERROR: $lib built without AV3A/libarcdav3a" >&2
  exit 1
fi
mkdir -p "$PREFIX"
echo "pic+av3a $(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$STAMP_FILE"
echo "ok FFmpeg+AV3A prefix: $PREFIX"
