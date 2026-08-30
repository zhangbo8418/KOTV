#!/usr/bin/env bash
# 桌面 libmpv 源码构建（Vulkan + AV3A：FongMi FFmpeg/libarcdav3a + FongMi mpv）。
# 用法: build-desktop-mpv-from-source.sh {linux|macos|windows}
# 环境变量：
#   KOTV_BUILD_MPV_AV3A=1     默认开启 AV3A（走 build-desktop-ffmpeg-av3a-prefix.sh）
#   KOTV_MPV_BUILD_DIR        构建缓存目录（默认 .build/desktop-mpv）
#   KOTV_MPV_JOBS             并行编译任务数
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLAT="${1:-}"
ASSET="$ROOT/flutter/assets/mpv-libs"
BUILD_DIR="${KOTV_MPV_BUILD_DIR:-$ROOT/.build/desktop-mpv}"
PREFIX="${KOTV_DESKTOP_FFMPEG_PREFIX:-$BUILD_DIR/prefix}"
MPV_REPO="${KOTV_MPV_REPO:-https://github.com/FongMi/mpv.git}"
MPV_COMMIT="${KOTV_MPV_COMMIT:-cca559b41ceb0bb7731cf6ef2e1f33276cd30c42}"
JOBS="${KOTV_MPV_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
AV3A="${KOTV_BUILD_MPV_AV3A:-1}"

mkdir -p "$ASSET/windows" "$ASSET/linux" "$ASSET/macos"

need() { command -v "$1" >/dev/null || { echo "need $1" >&2; exit 1; }; }

if ! command -v meson >/dev/null 2>&1; then
  for d in \
    "/c/hostedtoolcache/windows/Python/"*"/Scripts" \
    "$HOME/AppData/Roaming/Python/Python"*/Scripts \
    "$HOME/AppData/Local/Programs/Python/Python"*/Scripts; do
    [[ -d "$d" && -x "$d/meson.exe" ]] || continue
    export PATH="$d:$PATH"
    break
  done
fi
if ! command -v meson >/dev/null 2>&1; then
  if python3 -m meson --version >/dev/null 2>&1; then
    meson() { python3 -m meson "$@"; }
  elif python -m meson --version >/dev/null 2>&1; then
    meson() { python -m meson "$@"; }
  fi
fi
if ! command -v ninja >/dev/null 2>&1; then
  for d in \
    "/c/hostedtoolcache/windows/Python/"*"/Scripts" \
    "$HOME/AppData/Roaming/Python/Python"*/Scripts \
    "$HOME/AppData/Local/Programs/Python/Python"*/Scripts; do
    [[ -d "$d" && -x "$d/ninja.exe" ]] || continue
    export PATH="$d:$PATH"
    break
  done
fi

LIBPLACEBO_MIN="${KOTV_LIBPLACEBO_MIN:-7.360.1}"
LIBPLACEBO_TAG="${KOTV_LIBPLACEBO_TAG:-v7.360.1}"

ensure_libplacebo() {
  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/lib/x86_64-linux-gnu/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  if pkg-config --atleast-version="$LIBPLACEBO_MIN" libplacebo 2>/dev/null; then
    echo "ok libplacebo $(pkg-config --modversion libplacebo)"
    return
  fi
  echo "==> build libplacebo $LIBPLACEBO_TAG (need >= $LIBPLACEBO_MIN)"
  need meson
  need ninja
  mkdir -p "$BUILD_DIR"
  cd "$BUILD_DIR"
  if [[ ! -d libplacebo/.git ]]; then
    git clone --depth 1 --recurse-submodules --branch "$LIBPLACEBO_TAG" \
      https://github.com/haasn/libplacebo.git libplacebo
  else
    git -C libplacebo submodule update --init --recursive 2>/dev/null || true
  fi
  cd libplacebo
  rm -rf build
  meson setup build \
    --prefix="$PREFIX" \
    --libdir=lib \
    -Ddefault_library=shared \
    -Dvulkan=enabled \
    -Dopengl=disabled \
    -Ddemos=false \
    -Dtests=false
  meson compile -C build -j"$JOBS"
  meson install -C build
  # 某些平台仍会装到 lib/<triplet>/pkgconfig；一并加入 PATH
  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/lib/x86_64-linux-gnu/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  if ! pkg-config --atleast-version="$LIBPLACEBO_MIN" libplacebo; then
    echo "ERROR: libplacebo install not visible to pkg-config (>= $LIBPLACEBO_MIN)" >&2
    pkg-config --modversion libplacebo 2>&1 || true
    find "$PREFIX" -name 'libplacebo.pc' 2>/dev/null || true
    exit 1
  fi
  echo "ok libplacebo $(pkg-config --modversion libplacebo) (built)"
}

ensure_lua_pkg() {
  [[ "$(uname -s 2>/dev/null)" == "Darwin" ]] || return
  for lua_prefix in /opt/homebrew/opt/lua@5.2 /usr/local/opt/lua@5.2; do
    [[ -d "$lua_prefix/lib/pkgconfig" ]] || continue
    export PKG_CONFIG_PATH="$lua_prefix/lib/pkgconfig:$PKG_CONFIG_PATH"
  done
}

# Windows：用同一套 MinGW 源码编 libass（mpv-dev 包只有 libmpv 头，没有 libass）。
ensure_windows_libass() {
  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  if pkg-config --exists libass 2>/dev/null; then
    echo "ok libass $(pkg-config --modversion libass 2>/dev/null || echo found)"
    return
  fi
  need git
  need meson
  need ninja
  local tag="${KOTV_LIBASS_TAG:-0.17.3}"
  echo "==> build libass $tag (MinGW static, DirectWrite)"
  mkdir -p "$BUILD_DIR"
  cd "$BUILD_DIR"
  if [[ ! -d libass/.git ]]; then
    git clone --depth 1 --branch "$tag" https://github.com/libass/libass.git libass
  fi
  mkdir -p libass/subprojects
  cat >libass/subprojects/freetype2.wrap <<'EOF'
[wrap-git]
directory = freetype
url = https://github.com/freetype/freetype.git
revision = VER-2-13-3
depth = 1

[provide]
dependency_names = freetype2
EOF
  cat >libass/subprojects/fribidi.wrap <<'EOF'
[wrap-git]
directory = fribidi
url = https://github.com/fribidi/fribidi.git
revision = v1.0.16
depth = 1

[provide]
dependency_names = fribidi
EOF
  cat >libass/subprojects/harfbuzz.wrap <<'EOF'
[wrap-git]
directory = harfbuzz
url = https://github.com/harfbuzz/harfbuzz.git
revision = 8.5.0
depth = 1

[provide]
dependency_names = harfbuzz
EOF
  cd libass
  rm -rf build
  meson setup build \
    --prefix="$PREFIX" \
    --libdir=lib \
    -Ddefault_library=static \
    -Dfontconfig=disabled \
    -Dlibunibreak=disabled \
    -Dasm=disabled \
    --force-fallback-for=freetype2,fribidi,harfbuzz \
    -Dfreetype2:harfbuzz=disabled \
    -Dharfbuzz:tests=disabled \
    -Dharfbuzz:cairo=disabled \
    -Dharfbuzz:gobject=disabled \
    -Dharfbuzz:glib=disabled \
    -Dharfbuzz:freetype=disabled \
    -Dfribidi:docs=false \
    -Dfribidi:bin=false \
    -Dfribidi:tests=false
  meson compile -C build -j"$JOBS"
  meson install -C build
  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  pkg-config --exists libass \
    || { echo "ERROR: libass not visible after install" >&2; find "$PREFIX" -name 'libass*' >&2; exit 1; }
  echo "ok libass $(pkg-config --modversion libass) (built)"
}

ensure_windows_vulkan() {
  # libplacebo / mpv 需要 Vulkan 头与 vulkan-1
  if [[ -n "${VULKAN_SDK:-}" && -f "${VULKAN_SDK}/Include/vulkan/vulkan.h" ]]; then
    echo "ok VULKAN_SDK=$VULKAN_SDK"
  elif [[ -f "/c/VulkanSDK" ]] || ls /c/VulkanSDK/*/Include/vulkan/vulkan.h >/dev/null 2>&1; then
    local sdk
    sdk="$(ls -d /c/VulkanSDK/*/ 2>/dev/null | tail -1)"
    export VULKAN_SDK="$(cygpath -m "$sdk" 2>/dev/null || echo "$sdk")"
    echo "ok VULKAN_SDK=$VULKAN_SDK"
  else
    echo "WARN: VULKAN_SDK not set; libplacebo/meson may fail (CI should choco install vulkan-sdk)" >&2
  fi
  if [[ -n "${VULKAN_SDK:-}" ]]; then
    local pref inc lib
    pref="$(cygpath -m "${VULKAN_SDK}" 2>/dev/null || echo "${VULKAN_SDK}")"
    inc="$pref/Include"
    lib="$pref/Lib"
    mkdir -p "$PREFIX/lib/pkgconfig"
    cat >"$PREFIX/lib/pkgconfig/vulkan.pc" <<EOF
prefix=$pref
includedir=$inc
libdir=$lib

Name: Vulkan-Loader
Description: Vulkan Loader
Version: 1.3.0
Libs: -L\${libdir} -lvulkan-1
Cflags: -I\${includedir}
EOF
    export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    echo "ok vulkan.pc → $PREFIX/lib/pkgconfig/vulkan.pc"
  fi
}

build_mpv_linux() {
  need meson
  need ninja
  need git
  need pkg-config
  if [[ "$AV3A" == "1" ]]; then
    "$ROOT/scripts/build-desktop-ffmpeg-av3a-prefix.sh"
  fi
  ensure_libplacebo
  mkdir -p "$BUILD_DIR"
  cd "$BUILD_DIR"
  if [[ ! -d mpv/.git ]]; then
    git clone --filter=blob:none --depth 1 "$MPV_REPO" mpv
    git -C mpv fetch --depth 1 origin "$MPV_COMMIT"
    git -C mpv checkout -q "$MPV_COMMIT"
  else
    git -C mpv fetch --depth 1 origin "$MPV_COMMIT" 2>/dev/null || true
    git -C mpv checkout -q "$MPV_COMMIT"
  fi
  cd mpv
  rm -rf build
  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/lib/x86_64-linux-gnu/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  meson setup build \
    -Ddefault_library=shared \
    -Dlibmpv=true \
    -Dcplayer=false \
    -Dmanpage-build=disabled \
    -Dvulkan=enabled \
    -Dlua=disabled
  meson compile -C build -j"$JOBS"
  cp -f build/libmpv.so.2 "$ASSET/linux/libmpv.so.2"
  if [[ "$AV3A" == "1" ]]; then
    grep -aqE 'libarcdav3a|AV3A Audio Vivid' "$ASSET/linux/libmpv.so.2" \
      || { echo "ERROR: libmpv.so.2 missing AV3A symbols" >&2; exit 1; }
  fi
  echo "built linux/libmpv.so.2 (+ AV3A=$AV3A)"
}

build_mpv_macos() {
  need meson
  need ninja
  need git
  if [[ "$AV3A" == "1" ]]; then
    "$ROOT/scripts/build-desktop-ffmpeg-av3a-prefix.sh"
  fi
  ensure_lua_pkg
  mkdir -p "$BUILD_DIR"
  cd "$BUILD_DIR"
  if [[ ! -d mpv/.git ]]; then
    git clone --filter=blob:none --depth 1 "$MPV_REPO" mpv
    git -C mpv fetch --depth 1 origin "$MPV_COMMIT"
    git -C mpv checkout -q "$MPV_COMMIT"
  else
    git -C mpv fetch --depth 1 origin "$MPV_COMMIT" 2>/dev/null || true
    git -C mpv checkout -q "$MPV_COMMIT"
  fi
  cd mpv
  rm -rf build
  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  meson setup build \
    -Ddefault_library=shared \
    -Dlibmpv=true \
    -Dcplayer=false \
    -Dmanpage-build=disabled \
    -Dvulkan=enabled \
    -Dlua=disabled
  meson compile -C build -j"$JOBS"
  cp -f build/libmpv.dylib "$ASSET/macos/libmpv.dylib"
  if [[ "$AV3A" == "1" ]]; then
    grep -aqE 'libarcdav3a|AV3A Audio Vivid' "$ASSET/macos/libmpv.dylib" \
      || { echo "ERROR: libmpv.dylib missing AV3A symbols" >&2; exit 1; }
  fi
  echo "built macOS/libmpv.dylib (+ AV3A=$AV3A)"
}

build_mpv_windows() {
  need meson
  need ninja
  need git
  if [[ -d "/c/mingw-msvcrt/mingw64/bin" ]]; then
    export PATH="/c/mingw-msvcrt/mingw64/bin:$PATH"
  fi
  export CC="${CC:-gcc}"
  export CXX="${CXX:-g++}"
  if [[ "$AV3A" == "1" ]]; then
    "$ROOT/scripts/build-desktop-ffmpeg-av3a-prefix.sh"
  fi
  # FFmpeg 脚本在子进程里改 PATH 不会继承；这里强制自包含 pkg-config 在最前。
  local pkg_bin="$BUILD_DIR/bin" pc_win pkg_win cleaned="" part
  mkdir -p "$pkg_bin"
  cp -f "$ROOT/scripts/kotv-pkg-config.py" "$pkg_bin/kotv-pkg-config.py"
  cat >"$pkg_bin/pkg-config" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
if command -v python3 >/dev/null 2>&1; then
  exec python3 "$here/kotv-pkg-config.py" "$@"
fi
exec python "$here/kotv-pkg-config.py" "$@"
EOF
  chmod +x "$pkg_bin/pkg-config"
  cat >"$pkg_bin/pkg-config.cmd" <<'EOF'
@echo off
setlocal
set "HERE=%~dp0"
python "%HERE%kotv-pkg-config.py" %*
exit /b %ERRORLEVEL%
EOF
  IFS=':' read -ra _path_parts <<<"$PATH"
  for part in "${_path_parts[@]}"; do
    case "$part" in
      *[Ss]trawberry*) continue ;;
    esac
    if [[ -z "$cleaned" ]]; then cleaned="$part"; else cleaned="$cleaned:$part"; fi
  done
  export PATH="$pkg_bin:$cleaned"
  if command -v cygpath >/dev/null 2>&1; then
    export PKG_CONFIG_PATH="$(cygpath -m "$PREFIX/lib/pkgconfig")"
    pc_win="$(cygpath -m "$pkg_bin/pkg-config.cmd")"
    pkg_win="$(cygpath -m "$PREFIX/lib/pkgconfig")"
  else
    export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
    pc_win="$pkg_bin/pkg-config.cmd"
    pkg_win="$PREFIX/lib/pkgconfig"
  fi
  export PKG_CONFIG="$pkg_bin/pkg-config"
  echo "ok windows pkg-config: $PKG_CONFIG (PATH head=$pkg_bin)"
  "$PKG_CONFIG" --exists libavcodec \
    || { echo "ERROR: kotv-pkg-config cannot see libavcodec" >&2; ls -la "$PREFIX/lib/pkgconfig" >&2; exit 1; }
  echo "  libavcodec cflags=$("$PKG_CONFIG" --cflags libavcodec | head -c 200)"

  ensure_windows_vulkan
  ensure_windows_libass
  # 刷新 PKG_CONFIG_PATH（ensure_* 可能改过）
  if command -v cygpath >/dev/null 2>&1; then
    export PKG_CONFIG_PATH="$(cygpath -m "$PREFIX/lib/pkgconfig")"
    pc_win="$(cygpath -m "$pkg_bin/pkg-config.cmd")"
    pkg_win="$(cygpath -m "$PREFIX/lib/pkgconfig")"
  else
    export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
    pc_win="$pkg_bin/pkg-config.cmd"
    pkg_win="$PREFIX/lib/pkgconfig"
  fi
  ensure_libplacebo

  mkdir -p "$BUILD_DIR"
  cd "$BUILD_DIR"
  if [[ ! -d mpv/.git ]]; then
    git clone --filter=blob:none --depth 1 "$MPV_REPO" mpv
    git -C mpv fetch --depth 1 origin "$MPV_COMMIT"
    git -C mpv checkout -q "$MPV_COMMIT"
  else
    git -C mpv fetch --depth 1 origin "$MPV_COMMIT" 2>/dev/null || true
    git -C mpv checkout -q "$MPV_COMMIT"
  fi
  cd mpv
  rm -rf build
  cat >"$BUILD_DIR/meson-native-kotv.ini" <<EOF
[binaries]
pkg-config = '$pc_win'
pkgconfig = '$pc_win'

[built-in options]
pkg_config_path = '$pkg_win'
EOF
  meson setup build \
    --native-file "$BUILD_DIR/meson-native-kotv.ini" \
    -Ddefault_library=shared \
    -Dlibmpv=true \
    -Dcplayer=false \
    -Dmanpage-build=disabled \
    -Dvulkan=enabled \
    -Dlua=disabled
  meson compile -C build -j"$JOBS"
  local out="$ASSET/windows/mpv-2.dll"
  local dll=""
  for cand in build/mpv-2.dll build/libmpv-2.dll build/libmpv.dll; do
    [[ -f "$cand" ]] && dll="$cand" && break
  done
  [[ -n "$dll" ]] || dll="$(find build -maxdepth 2 -name 'mpv-2.dll' -o -name 'libmpv-2.dll' 2>/dev/null | head -1 || true)"
  [[ -n "$dll" && -f "$dll" ]] || { echo "ERROR: mpv dll not found under build/" >&2; exit 1; }
  cp -f "$dll" "$out"
  # 运行时依赖：libass 等
  if [[ -d "$PREFIX/bin" ]]; then
    find "$PREFIX/bin" -maxdepth 1 -iname '*.dll' -exec cp -f {} "$ASSET/windows/" \;
  fi
  if [[ "$AV3A" == "1" ]]; then
    grep -aqE 'libarcdav3a|AV3A Audio Vivid' "$out" \
      || { echo "ERROR: mpv-2.dll missing AV3A symbols" >&2; exit 1; }
  fi
  echo "built windows/mpv-2.dll (+ AV3A=$AV3A) from $dll"
}

case "$PLAT" in
  linux)
    build_mpv_linux
    ;;
  macos|darwin)
    build_mpv_macos
    ;;
  windows|win)
    build_mpv_windows
    ;;
  *)
    echo "usage: $0 {linux|macos|windows}" >&2
    exit 1
    ;;
esac

chmod +x "$ROOT/scripts/verify-desktop-mpv-libs.sh" 2>/dev/null || true
KOTV_VERIFY_PLAT="$PLAT" KOTV_EXPECT_MPV_AV3A="${AV3A}" "$ROOT/scripts/verify-desktop-mpv-libs.sh"
