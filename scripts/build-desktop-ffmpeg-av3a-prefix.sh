#!/usr/bin/env bash
# 桌面 FFmpeg 前缀：FongMi FFmpeg 9 + dependency/avs3a（libarcdav3a / AV3A，与移动端一致）。
# 支持 Linux / macOS / Windows(GitHub Actions MinGW)。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${KOTV_MPV_BUILD_DIR:-$ROOT/.build/desktop-mpv}"
PREFIX="${KOTV_DESKTOP_FFMPEG_PREFIX:-$BUILD_DIR/prefix}"
FFMPEG_REPO="${KOTV_FFMPEG_REPO:-https://github.com/FongMi/FFmpeg.git}"
# 跟 FongMi 的 FFmpeg 9 分支 tip；要钉死某次提交再设 KOTV_FFMPEG_COMMIT。
FFMPEG_REF="${KOTV_FFMPEG_REF:-release-9.0-fongmi}"
JOBS="${KOTV_MPV_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "${NUMBER_OF_PROCESSORS:-4}")}"
PKG_BIN="$BUILD_DIR/bin"

resolve_ffmpeg_sha() {
  if [[ -n "${KOTV_FFMPEG_COMMIT:-}" ]]; then
    printf '%s\n' "$KOTV_FFMPEG_COMMIT"
    return
  fi
  local sha
  sha="$(git ls-remote "$FFMPEG_REPO" "refs/heads/${FFMPEG_REF}" | awk '{print $1; exit}')"
  [[ -n "$sha" ]] || { echo "ERROR: cannot resolve $FFMPEG_REPO $FFMPEG_REF" >&2; exit 1; }
  printf '%s\n' "$sha"
}

FFMPEG_COMMIT="$(resolve_ffmpeg_sha)"
echo "ok FFmpeg ${FFMPEG_REF} → ${FFMPEG_COMMIT:0:12}"

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
  mkdir -p "$BUILD_DIR"
  if [[ ! -d ffmpeg/.git ]]; then
    git clone --filter=blob:none "$FFMPEG_REPO" ffmpeg
  fi
  git -C ffmpeg fetch --depth 1 origin "$FFMPEG_COMMIT" \
    || git -C ffmpeg fetch --depth 1 origin "$FFMPEG_REF"
  git -C ffmpeg checkout -q "$FFMPEG_COMMIT" \
    || git -C ffmpeg checkout -q FETCH_HEAD
  # 确保落到 resolve 出来的 tip（分支 tip 可能比 FETCH_HEAD 更新）。
  if [[ "$(git -C ffmpeg rev-parse HEAD)" != "$FFMPEG_COMMIT" ]]; then
    git -C ffmpeg fetch --depth 1 origin "$FFMPEG_COMMIT"
    git -C ffmpeg checkout -q "$FFMPEG_COMMIT"
  fi
}

# v18: arib PIC；Windows libavcodec/arib 补 d2d1。
# v17: zlib PIC；xz 只装 liblzma；FFmpeg/libxml 用 LIBXML_STATIC。
# v16: codecs 静态 zlib/lzma；mac 探测链 -lc++；清 DYLD 防 Abort。
# v15: libxml2 完整启用 zlib+lzma（PREFIX 自带依赖）。
# v14: +dav1d +libxml2 +libaribcaption + 平台硬解（d3d11va/videotoolbox/vaapi）。
# HTTP/2+3 仍走 mpv libcurl。伪装扩展名分片靠播放器 extension_picky=0。
STAMP_FILE="$PREFIX/.kotv-ffmpeg-av3a-v18-${FFMPEG_COMMIT:0:12}"

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

# meson 链 libmpv 时若不带 --static，Libs.private 会被丢掉；把关键静态库提到 Libs。
promote_static_libs_in_avcodec_pc() {
  local pc="$PREFIX/lib/pkgconfig/libavcodec.pc"
  [[ -f "$pc" ]] || return 0
  local win=0
  kotv_is_windows_build && win=1
  python3 - "$pc" "$win" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
win = sys.argv[2] == "1"
lines = p.read_text(encoding="utf-8", errors="replace").splitlines(True)
need = ["-larcdav3a", "-ldav1d", "-laribcaption", "-lxml2", "-lz", "-llzma"]
if win:
    need += ["-lstdc++", "-ld2d1", "-ldwrite", "-lole32", "-luuid"]
out = []
for line in lines:
    if line.startswith("Libs:"):
        nl = "\n" if line.endswith("\n") else ""
        body = line.rstrip("\r\n")
        for lib in need:
            if lib not in body:
                body += f" {lib}"
        if "-lm" not in body:
            body += " -lm"
        line = body + nl
    out.append(line)
p.write_text("".join(out), encoding="utf-8")
PY
  echo "ok patched $pc (+ arcdav3a/dav1d/aribcaption/xml2/zlib/lzma${win:+/d2d1} on Libs)"
}

promote_arcdav3a_in_avcodec_pc() {
  promote_static_libs_in_avcodec_pc
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
  promote_arcdav3a_in_avcodec_pc
  if kotv_is_windows_build; then
    install_pkg_config_wrapper
  fi
  exit 0
fi

echo "==> build desktop FFmpeg+AV3A prefix → $PREFIX ($(uname -s))"
clone_ffmpeg

# dav1d / libxml2 / libaribcaption（与安卓对齐）
chmod +x "$ROOT/scripts/ensure-desktop-ffmpeg-codecs.sh"
KOTV_MPV_BUILD_DIR="$BUILD_DIR" KOTV_DESKTOP_FFMPEG_PREFIX="$PREFIX" \
  "$ROOT/scripts/ensure-desktop-ffmpeg-codecs.sh"
export PKG_CONFIG_PATH="$(kotv_native_path "$PREFIX/lib/pkgconfig")${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

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
  echo "==> Windows: bypass arcdav3a/dav1d/xml2/arib pkg-config probes"
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
    # dav1d / libxml2 / libaribcaption：Windows pkg-config 探测不稳（Requires.private / 头路径）。
    # libxml：FongMi 探测头 libxml2/libxml/... + 源码 libxml/...，两个 -I 都要。
    perl -i -pe "s#enabled libdav1d\\s+&& require_pkg_config libdav1d .*#enabled libdav1d \&\& enable libdav1d \&\& add_cflags -I${PREF_NATIVE}/include \&\& add_extralibs -L${PREF_NATIVE}/lib -ldav1d#" configure
    perl -i -pe "s#enabled libxml2\\s+&& require_pkg_config libxml2 .*#enabled libxml2 \&\& enable libxml2 \&\& add_cflags -I${PREF_NATIVE}/include -I${PREF_NATIVE}/include/libxml2 -DLIBXML_STATIC \&\& add_extralibs -L${PREF_NATIVE}/lib -lxml2 -lz -llzma#" configure
    perl -i -pe "s#enabled libaribcaption\\s+&& require_pkg_config libaribcaption .*#enabled libaribcaption \&\& enable libaribcaption \&\& add_cflags -I${PREF_NATIVE}/include \&\& add_extralibs -L${PREF_NATIVE}/lib -laribcaption -lstdc++ -ld2d1 -ldwrite -lole32 -luuid#" configure
  else
    sed -i.bak "s#require_pkg_config libarcdav3a arcdav3a decoder.h avs3_create_decoder#enable libarcdav3a \&\& add_cflags -I${PREF_NATIVE}/include \&\& add_extralibs -L${PREF_NATIVE}/lib -larcdav3a -lm#" configure
  fi
  grep -nE 'libarcdav3a|libdav1d|libxml2|libaribcaption' configure | head -20
fi

# HTTPS/302：Win=Schannel；Linux=OpenSSL；macOS=SecureTransport。
# RTSP/RTMP：FFmpeg 内置。HTTP/2·HTTP/3：FongMi FFmpeg 无 --enable-libnghttp2，由 mpv libcurl 栈提供。
setup_pkg_config

# FFmpeg configure 会把 --extra-ldflags/--extra-libs 用在最早的 cc 探测上；
# 清掉可能污染运行探测的动态库搜索路径（mac Abort trap: 6）。
unset DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH LD_LIBRARY_PATH LIBRARY_PATH 2>/dev/null || true
rm -f "$PREFIX/lib"/libz*.dylib "$PREFIX/lib"/liblzma*.dylib 2>/dev/null || true

FFMPEG_EXTRA=(--extra-cflags="-I${PREF_NATIVE}/include -I${PREF_NATIVE}/include/libxml2 -DLIBXML_STATIC")
FFMPEG_EXTRA+=(--extra-ldflags="-L${PREF_NATIVE}/lib")
# 播放不需要 avdevice；与 fvp/mdk 同进程时 libavdevice 易引入重复注册/堆损坏（mac ObjC 类，Win Vulkan 路径 talloc）。
FFMPEG_EXTRA+=(--disable-avdevice)
FFMPEG_EXTRA+=(--enable-network)
# 与安卓对齐的外置解码/解析库。
FFMPEG_EXTRA+=(--enable-libdav1d)
FFMPEG_EXTRA+=(--enable-libxml2)
FFMPEG_EXTRA+=(--enable-libaribcaption)
if kotv_is_windows_build; then
  FFMPEG_EXTRA+=(--target-os=mingw64 --arch=x86_64)
  FFMPEG_EXTRA+=(--pkg-config="$PKG_BIN/pkg-config")
  # 勿对 FFmpeg 全局 -D_WIN32_WINNT=0x0601：mf_utils 会缺 Win8+ 符号而编不过。
  FFMPEG_EXTRA+=(--disable-mediafoundation)
  # 原生 Schannel，避免 MinGW 编 OpenSSL（MSYS perl 缺 Locale::Maketext）。
  FFMPEG_EXTRA+=(--enable-schannel)
  FFMPEG_EXTRA+=(--enable-d3d11va)
  FFMPEG_EXTRA+=(--extra-libs="-larcdav3a -ldav1d -laribcaption -lxml2 -lz -llzma -lm -lcrypt32 -lsecur32 -lws2_32 -lstdc++ -ld2d1 -ldwrite -lole32 -luuid")
elif [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
  # Apple ld（Xcode 15+/26）对 nasm 产物报 unknown platform；经典链接器已移除。
  FFMPEG_EXTRA+=(--disable-x86asm)
  FFMPEG_EXTRA+=(--enable-securetransport)
  FFMPEG_EXTRA+=(--enable-videotoolbox)
  # arib 是 C++；探测阶段也会链 extra-libs。
  FFMPEG_EXTRA+=(--extra-libs="-larcdav3a -ldav1d -laribcaption -lxml2 -lz -llzma -lm -lc++")
  export CC="${CC:-clang}"
  export CXX="${CXX:-clang++}"
else
  FFMPEG_EXTRA+=(--enable-openssl)
  FFMPEG_EXTRA+=(--enable-vaapi)
  FFMPEG_EXTRA+=(--extra-libs="-larcdav3a -ldav1d -laribcaption -lxml2 -lz -llzma -lm -lstdc++")
fi

# 旧前缀可能残留 libavdevice.pc（无 .a）；meson 会回退到 Homebrew 共享库。
rm -f "$PREFIX/lib/pkgconfig/libavdevice.pc" "$PREFIX/lib/libavdevice"* 2>/dev/null || true

# mac：configure 早期会链 extra-libs 并执行探测；先自测，避免只见 Abort trap。
if [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
  probe_src="$BUILD_DIR/ffmpeg_cc_probe.c"
  probe_bin="$BUILD_DIR/ffmpeg_cc_probe"
  cat >"$probe_src" <<'PROBE'
int main(void) { return 0; }
PROBE
  probe_cc="${CC:-clang}"
  if ! "$probe_cc" -O0 -I"$PREF_NATIVE/include" -I"$PREF_NATIVE/include/libxml2" -DLIBXML_STATIC \
      -L"$PREF_NATIVE/lib" -o "$probe_bin" "$probe_src" \
      -larcdav3a -ldav1d -laribcaption -lxml2 -lz -llzma -lm -lc++ \
      2>"$BUILD_DIR/ffmpeg_cc_probe.log"; then
    echo "ERROR: pre-configure link probe failed ($probe_cc):" >&2
    cat "$BUILD_DIR/ffmpeg_cc_probe.log" >&2
    ls -la "$PREFIX/lib"/libz* "$PREFIX/lib"/liblzma* "$PREFIX/lib"/libxml* "$PREFIX/lib"/libarib* 2>/dev/null || true
    exit 1
  fi
  if ! "$probe_bin" >/dev/null 2>"$BUILD_DIR/ffmpeg_cc_probe_run.log"; then
    echo "ERROR: pre-configure run probe aborted (often bad dylib under PREFIX/lib):" >&2
    cat "$BUILD_DIR/ffmpeg_cc_probe_run.log" >&2 || true
    ls -la "$PREFIX/lib"/libz* "$PREFIX/lib"/liblzma* "$PREFIX/lib"/libxml* 2>/dev/null || true
    file "$probe_bin" 2>/dev/null || true
    exit 1
  fi
  echo "ok FFmpeg cc link+run probe"
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
  if [[ -f ffbuild/config.log ]]; then
    tail -80 ffbuild/config.log >&2
  else
    echo "(ffbuild/config.log missing)" >&2
    ls -la ffbuild 2>/dev/null >&2 || true
  fi
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
if ! grep -aqE 'libdav1d|dav1d_data_props' "$lib" 2>/dev/null \
  && ! grep -aq 'dav1d' "$PREFIX/lib/pkgconfig/libavcodec.pc" 2>/dev/null; then
  echo "ERROR: $lib built without libdav1d" >&2
  exit 1
fi
# lavf：HTTPS + 直播常用 RTSP/RTMP（FongMi 无 libnghttp2 选项；HTTP/2+3 走 mpv libcurl）。
if [[ -f ffbuild/config.h ]]; then
  fail_proto=0
  if ! grep -qE '^#define CONFIG_HTTPS_PROTOCOL 1$' ffbuild/config.h; then
    echo "ERROR: FFmpeg missing CONFIG_HTTPS_PROTOCOL=1" >&2
    fail_proto=1
  fi
  if ! grep -qE '^#define CONFIG_HTTP_PROTOCOL 1$' ffbuild/config.h; then
    echo "ERROR: FFmpeg missing CONFIG_HTTP_PROTOCOL=1" >&2
    fail_proto=1
  fi
  if ! grep -qE '^#define CONFIG_RTSP_(DEMUXER|PROTOCOL) 1$' ffbuild/config.h; then
    echo "ERROR: FFmpeg missing RTSP demuxer/protocol" >&2
    fail_proto=1
  fi
  if ! grep -qE '^#define CONFIG_RTMP(_PROTOCOL|_DEMUXER)? 1$' ffbuild/config.h \
    && ! grep -qE '^#define CONFIG_RTMP[A-Z_]*PROTOCOL 1$' ffbuild/config.h; then
    echo "ERROR: FFmpeg missing RTMP protocol" >&2
    fail_proto=1
  fi
  for feat in LIBDAV1D LIBXML2 LIBARIBCAPTION; do
    if ! grep -qE "^#define CONFIG_${feat} 1\$" ffbuild/config.h; then
      echo "ERROR: FFmpeg missing CONFIG_${feat}=1" >&2
      fail_proto=1
    fi
  done
  if kotv_is_windows_build; then
    if ! grep -qE '^#define CONFIG_D3D11VA 1$' ffbuild/config.h; then
      echo "ERROR: FFmpeg missing CONFIG_D3D11VA=1" >&2
      fail_proto=1
    fi
  elif [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
    if ! grep -qE '^#define CONFIG_VIDEOTOOLBOX 1$' ffbuild/config.h; then
      echo "ERROR: FFmpeg missing CONFIG_VIDEOTOOLBOX=1" >&2
      fail_proto=1
    fi
  else
    if ! grep -qE '^#define CONFIG_VAAPI 1$' ffbuild/config.h; then
      echo "ERROR: FFmpeg missing CONFIG_VAAPI=1" >&2
      fail_proto=1
    fi
  fi
  if [[ "$fail_proto" != 0 ]]; then
    grep -E 'CONFIG_(HTTPS|HTTP_PROTOCOL|RTSP|RTMP|OPENSSL|SCHANNEL|SECURETRANSPORT|LIBDAV1D|LIBXML2|LIBARIBCAPTION|D3D11VA|VIDEOTOOLBOX|VAAPI)' ffbuild/config.h | head -80 >&2 || true
    exit 1
  fi
  echo "ok FFmpeg: HTTPS/RTSP/RTMP + dav1d/xml2/arib + hwaccel"
fi
mkdir -p "$PREFIX"
promote_arcdav3a_in_avcodec_pc
echo "pic+av3a+dav1d+xml2+arib+hw+tls+rtsp+rtmp $(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$STAMP_FILE"
echo "ok FFmpeg+AV3A+dav1d+xml2+arib+hwaccel prefix: $PREFIX"
