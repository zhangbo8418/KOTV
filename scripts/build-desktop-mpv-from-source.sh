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

kotv_is_windows_build() {
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
  esac
  [[ "${OS:-}" == "Windows_NT" ]]
}

# Win7 发行包：libmpv 仅 D3D11（不编 vulkan/gpu-next 依赖链）。
kotv_is_mpv_win7_build() {
  [[ "${KOTV_MPV_WIN7:-${KOTV_WIN7:-0}}" == "1" ]]
}

kotv_libplacebo_profile() {
  if kotv_is_mpv_win7_build; then
    echo "win7-d3d11"
  else
    echo "vulkan"
  fi
}

# 桌面 libmpv 须能在 Win7 加载：目标子系统 6.01，避免 import SHCORE.dll（Win8+）。
kotv_windows_mpv_cflags() {
  printf '%s' "-D_WIN32_WINNT=0x0601 -DWINVER=0x0601 -DNTDDI_VERSION=0x06010000"
}

verify_mpv_win7_imports() {
  local dll="$1"
  [[ -f "$dll" ]] || return 0
  if command -v objdump >/dev/null 2>&1; then
    if objdump -p "$dll" 2>/dev/null | awk '/DLL Name:/{print $3}' | tr '[:upper:]' '[:lower:]' | grep -qx 'shcore.dll'; then
      echo "ERROR: $dll imports SHCORE.dll (Win7 incompatible; rebuild with kotv_windows_mpv_cflags)" >&2
      exit 1
    fi
  fi
}

apply_mpv_win7_patches() {
  local patch="$ROOT/scripts/patches/mpv-win7-desktop.patch"
  [[ -f "$patch" ]] || { echo "ERROR: missing $patch" >&2; exit 1; }
  if patch -p0 --forward --batch -d . <"$patch"; then
    echo "ok applied mpv Win7 patches"
  elif patch -p0 -R --dry-run -d . <"$patch" >/dev/null 2>&1; then
    echo "ok mpv Win7 patches already applied"
  else
    echo "ERROR: failed to apply mpv Win7 patches" >&2
    exit 1
  fi
}

kotv_windows_path() {
  local p="${1:-}"
  [[ -n "$p" ]] || return 1
  p="${p//\\//}"
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -u "$p" 2>/dev/null || printf '%s' "$p"
  else
    printf '%s' "$p"
  fi
}

# SDK 1.4.313+ 的 Bin/ 常无 vulkan-1.dll（Runtime 单独安装到 System32 或 Helpers）。
kotv_extract_vulkan_loader_from_exe() {
  local exe="$1"
  local tmp="${BUILD_DIR}/vulkan-rt-extract"
  local cand=""
  [[ -f "$exe" ]] || return 1
  rm -rf "$tmp"
  mkdir -p "$tmp"
  if command -v 7z >/dev/null 2>&1; then
    7z x -y "-o$tmp" "$exe" >/dev/null 2>&1 || true
  elif command -v 7za >/dev/null 2>&1; then
    7za x -y "-o$tmp" "$exe" >/dev/null 2>&1 || true
  else
    return 1
  fi
  cand="$(find "$tmp" -name 'vulkan-1.dll' 2>/dev/null | head -1 || true)"
  [[ -n "$cand" && -f "$cand" ]] || return 1
  printf '%s' "$cand"
}

kotv_find_vulkan_loader_dll() {
  local sdk cand dir rt cache url
  # choco vulkan-sdk 通常已把 Runtime 装进 System32（优先，避免 Helpers 安装器卡死）
  for cand in /c/Windows/System32/vulkan-1.dll /c/WINDOWS/System32/vulkan-1.dll; do
    [[ -f "$cand" ]] && { printf '%s' "$cand"; return 0; }
  done
  for sdk in \
    "$(kotv_windows_path "${VULKAN_SDK:-}" 2>/dev/null || true)" \
    "$(ls -d /c/VulkanSDK/*/ 2>/dev/null | tail -1 || true)"; do
    [[ -n "$sdk" ]] || continue
    sdk="${sdk%/}"
    for cand in "$sdk/Bin/vulkan-1.dll" "$sdk/Bin32/vulkan-1.dll"; do
      [[ -f "$cand" ]] && { printf '%s' "$cand"; return 0; }
    done
    for dir in "$sdk/Helpers" "$sdk/helpers"; do
      [[ -d "$dir" ]] || continue
      for rt in "$dir"/*.exe; do
        [[ -f "$rt" ]] || continue
        case "$(basename "$rt" | tr '[:upper:]' '[:lower:]')" in
          vulkanrt*.exe|*vulkan*runtime*.exe)
            echo "==> extract vulkan-1.dll from $(basename "$rt")" >&2
            cand="$(kotv_extract_vulkan_loader_from_exe "$rt" || true)"
            [[ -n "$cand" && -f "$cand" ]] && { printf '%s' "$cand"; return 0; }
            ;;
        esac
      done
    done
  done
  cache="${BUILD_DIR}/vulkan-runtime.exe"
  url="${KOTV_VULKAN_RUNTIME_URL:-https://sdk.lunarg.com/sdk/download/latest/windows/vulkan-runtime.exe}"
  mkdir -p "$BUILD_DIR"
  if [[ ! -f "$cache" ]]; then
    echo "==> fetch vulkan-runtime.exe (SDK Bin has no vulkan-1.dll)" >&2
    curl -fsSL --connect-timeout 30 --max-time 600 -o "$cache" "$url" || return 1
  fi
  echo "==> extract vulkan-1.dll from vulkan-runtime.exe" >&2
  cand="$(kotv_extract_vulkan_loader_from_exe "$cache" || true)"
  [[ -n "$cand" && -f "$cand" ]] && { printf '%s' "$cand"; return 0; }
  return 1
}

kotv_meson_compile() {
  local dir="$1"
  local label="${2:-meson compile}"
  echo "==> $label started $(date -u +%Y-%m-%dT%H:%M:%SZ) -j$JOBS"
  if kotv_is_windows_build; then
    # Git Bash + CI：ninja 默认缓冲输出，长时间像卡死；--verbose 刷进度
    meson compile -C "$dir" -j"$JOBS" --verbose
  else
    meson compile -C "$dir" -j"$JOBS"
  fi
  echo "==> $label finished $(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

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

# 系统 DLL，不打进安装包。
_harvest_is_system_dll() {
  local lower
  lower="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    kernel32.dll|user32.dll|gdi32.dll|gdiplus.dll|advapi32.dll|shell32.dll|ole32.dll|oleaut32.dll| \
    ws2_32.dll|wsock32.dll|winmm.dll|dwmapi.dll|d3d9.dll|d3d11.dll|d3d12.dll|dxgi.dll|dxva2.dll| \
    opengl32.dll|ntdll.dll|msvcrt.dll|ucrtbase.dll|sechost.dll|rpcrt4.dll|comdlg32.dll|comctl32.dll| \
    imm32.dll|setupapi.dll|cfgmgr32.dll|version.dll|shlwapi.dll|crypt32.dll|bcrypt.dll|iphlpapi.dll| \
    dnsapi.dll|normaliz.dll|winhttp.dll|wininet.dll|avrt.dll|avicap32.dll|ncrypt.dll|secur32.dll| \
    uxtheme.dll|mfplat.dll|mf.dll|mfreadwrite.dll| \
    msvcp*.dll|vcruntime*.dll|concrt*.dll|api-ms-*|ext-ms-*|kernelbase.dll|userenv.dll| \
    powrprof.dll|wtsapi32.dll|dbghelp.dll|psapi.dll|oleacc.dll) return 0 ;;
  esac
  return 1
}

_harvest_copy_dll() {
  local from="$1" to="$2"
  [[ -f "$from" ]] || return 0
  # MSYS/Git Bash：cp 同一文件会报 "are the same file" 并非零退出。
  [[ "$from" -ef "$to" ]] && return 0
  cp -f "$from" "$to"
}

_harvest_copy_tree_dlls() {
  local src="$1" dest="$2" depth="${3:-8}"
  [[ -d "$src" ]] || return 0
  local f base
  while IFS= read -r f; do
    base="$(basename "$f")"
    case "$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')" in
      mpv-2.dll|libmpv-2.dll) continue ;;
    esac
    _harvest_copy_dll "$f" "$dest/$base"
  done < <(find "$src" -maxdepth "$depth" -type f -iname '*.dll' 2>/dev/null)
}

# 把 mpv-2.dll 的非系统依赖拷进 assets/windows（与 exe 同目录加载）。
harvest_windows_mpv_dlls() {
  local dest="$ASSET/windows"
  local dll="$dest/mpv-2.dll"
  mkdir -p "$dest"
  [[ -f "$dll" ]] || return 0

  local src
  for src in "$PREFIX/bin" "$PREFIX/lib" "$BUILD_DIR/prefix/bin" "$BUILD_DIR/prefix/lib" \
             "$BUILD_DIR/mpv/build" "$BUILD_DIR/libplacebo/build"; do
    _harvest_copy_tree_dlls "$src" "$dest" 3
  done
  _harvest_copy_tree_dlls "$PREFIX" "$dest" 8

  local vk
  if ! kotv_is_mpv_win7_build; then
    vk="$(kotv_find_vulkan_loader_dll || true)"
    if [[ -n "$vk" && -f "$vk" ]]; then
      echo "ok vulkan-1.dll ← $vk"
      _harvest_copy_dll "$vk" "$dest/vulkan-1.dll"
    fi
  else
    echo "skip vulkan-1.dll (Win7 D3D11-only libmpv build)"
  fi

  local gcc_bin=""
  local -a search_dirs=()
  if command -v gcc >/dev/null 2>&1; then
    gcc_bin="$(cd "$(dirname "$(command -v gcc)")" && pwd)"
    search_dirs+=("$gcc_bin")
    local printed
    for printed in libstdc++-6.dll libgcc_s_seh-1.dll libwinpthread-1.dll; do
      src="$(gcc -print-file-name="$printed" 2>/dev/null || true)"
      [[ -n "$src" && -f "$src" && "$src" != "$printed" ]] && _harvest_copy_dll "$src" "$dest/$(basename "$src")"
    done
  fi
  if [[ -n "$gcc_bin" ]]; then
    local mingw
    for mingw in libgcc_s_seh-1.dll libstdc++-6.dll libwinpthread-1.dll libssp-0.dll; do
      [[ -f "$gcc_bin/$mingw" ]] && _harvest_copy_dll "$gcc_bin/$mingw" "$dest/$mingw"
    done
  fi

  search_dirs+=(
    "$PREFIX/bin" "$PREFIX/lib"
    "$BUILD_DIR/libplacebo/build" "$BUILD_DIR/libplacebo/build/src"
  )

  if command -v objdump >/dev/null 2>&1; then
    local round=0 changed=1 name dllpath
    while [[ "$changed" == 1 && "$round" -lt 5 ]]; do
      changed=0
      round=$((round + 1))
      while IFS= read -r dllpath; do
        [[ -f "$dllpath" ]] || continue
        while read -r name; do
          [[ -n "$name" ]] || continue
          _harvest_is_system_dll "$name" && continue
          [[ -f "$dest/$name" ]] && continue
          for src in "${search_dirs[@]}"; do
            [[ -n "$src" && -f "$src/$name" ]] || continue
            _harvest_copy_dll "$src/$name" "$dest/$name"
            changed=1
            break
          done
        done < <(objdump -p "$dllpath" 2>/dev/null | awk '/DLL Name:/{print $3}')
      done < <(find "$dest" -maxdepth 1 -type f -iname '*.dll')
    done
  fi

  local n
  n="$(find "$dest" -maxdepth 1 -type f -iname '*.dll' | wc -l | tr -d ' ')"
  echo "harvested $n dlls → $dest"
  find "$dest" -maxdepth 1 -type f -iname '*.dll' -printf '  %f\n' 2>/dev/null \
    || find "$dest" -maxdepth 1 -type f -iname '*.dll' | sed 's|.*/||;s|^|  |'
  if ! kotv_is_mpv_win7_build && [[ ! -f "$dest/vulkan-1.dll" ]]; then
    echo "ERROR: harvested windows dlls missing vulkan-1.dll (tried SDK Bin, System32, vulkan-runtime.exe)" >&2
    ls -la /c/VulkanSDK/*/Bin/vulkan-1.dll /c/Windows/System32/vulkan-1.dll 2>/dev/null || true
    exit 1
  fi
  chmod +x "$ROOT/scripts/verify-windows-mpv-bundle.sh"
  "$ROOT/scripts/verify-windows-mpv-bundle.sh" "$dest"
}
LIBPLACEBO_MIN="${KOTV_LIBPLACEBO_MIN:-7.360.1}"
LIBPLACEBO_TAG="${KOTV_LIBPLACEBO_TAG:-v7.360.1}"

ensure_libplacebo() {
  local want_profile cached_profile
  want_profile="$(kotv_libplacebo_profile)"
  cached_profile="$(cat "$BUILD_DIR/.libplacebo-profile" 2>/dev/null || true)"
  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/lib/x86_64-linux-gnu/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  if pkg-config --atleast-version="$LIBPLACEBO_MIN" libplacebo 2>/dev/null; then
    if [[ "$cached_profile" == "$want_profile" ]]; then
      if kotv_is_windows_build && [[ ! -f "$PREFIX/lib/libplacebo.a" ]]; then
        echo "==> windows: prefix libplacebo is not static; rebuilding ($want_profile)"
      else
        echo "ok libplacebo $(pkg-config --modversion libplacebo) (profile=$want_profile)"
        return
      fi
    else
      echo "==> libplacebo profile ${cached_profile:-<none>} -> $want_profile, rebuilding"
      rm -f "$PREFIX/lib/libplacebo.a" "$PREFIX/lib/pkgconfig/libplacebo.pc" 2>/dev/null || true
    fi
  fi
  echo "==> build libplacebo $LIBPLACEBO_TAG (profile=$want_profile, need >= $LIBPLACEBO_MIN)"
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
  local placebo_lib=shared
  local vk_flag=enabled
  kotv_is_mpv_win7_build && vk_flag=disabled
  if kotv_is_windows_build; then
    placebo_lib=static
    echo "==> windows: static libplacebo (profile=$want_profile, vulkan=$vk_flag)"
    export CFLAGS="${CFLAGS:-} $(kotv_windows_mpv_cflags)"
    export CXXFLAGS="${CXXFLAGS:-} $(kotv_windows_mpv_cflags)"
    local -a placebo_extra=()
    local -a native_args=()
    local native_ini="$BUILD_DIR/meson-native-kotv.ini"
    # Win7 D3D11 需要 shaderc；meson 必须用我们注入的 pkg-config（.cmd），
    # 否则报 “Pkg-config for machine host machine not found”。
    if [[ -f "$native_ini" ]]; then
      native_args+=(--native-file="$native_ini")
      echo "  using meson native-file: $native_ini"
    elif [[ -n "${PKG_CONFIG:-}" ]]; then
      echo "WARN: meson-native-kotv.ini missing; relying on PKG_CONFIG=$PKG_CONFIG" >&2
    fi
    if kotv_is_mpv_win7_build; then
      placebo_extra+=(-Dd3d11=enabled -Dshaderc=enabled)
    fi
    meson setup build \
      --prefix="$PREFIX" \
      --libdir=lib \
      "${native_args[@]}" \
      -Ddefault_library="$placebo_lib" \
      -Dvulkan="$vk_flag" \
      "${placebo_extra[@]}" \
      -Dopengl=disabled \
      -Ddemos=false \
      -Dtests=false \
      -Dc_args="['-D_WIN32_WINNT=0x0601','-DWINVER=0x0601','-DNTDDI_VERSION=0x06010000']" \
      -Dcpp_args="['-D_WIN32_WINNT=0x0601','-DWINVER=0x0601','-DNTDDI_VERSION=0x06010000']"
  else
    meson setup build \
      --prefix="$PREFIX" \
      --libdir=lib \
      -Ddefault_library="$placebo_lib" \
      -Dvulkan=enabled \
      -Dopengl=disabled \
      -Ddemos=false \
      -Dtests=false
  fi
  kotv_meson_compile build "libplacebo"
  meson install -C build
  echo "$want_profile" > "$BUILD_DIR/.libplacebo-profile"
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
  if kotv_is_windows_build; then
    export CFLAGS="${CFLAGS:-} $(kotv_windows_mpv_cflags)"
    export CXXFLAGS="${CXXFLAGS:-} $(kotv_windows_mpv_cflags)"
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
      -Dfribidi:tests=false \
      -Dc_args="['-D_WIN32_WINNT=0x0601','-DWINVER=0x0601','-DNTDDI_VERSION=0x06010000']" \
      -Dcpp_args="['-D_WIN32_WINNT=0x0601','-DWINVER=0x0601','-DNTDDI_VERSION=0x06010000']"
  else
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
  fi
  kotv_meson_compile build "libass"
  meson install -C build
  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  pkg-config --exists libass \
    || { echo "ERROR: libass not visible after install" >&2; find "$PREFIX" -name 'libass*' >&2; exit 1; }
  echo "ok libass $(pkg-config --modversion libass) (built)"
}

# Win7：不装 Vulkan SDK，但 mpv/libplacebo 的 d3d11 必须有 shaderc + spirv-cross。
ensure_windows_d3d11_shader_deps() {
  kotv_is_mpv_win7_build || return 0
  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  local need_shaderc=0 need_spirv=0
  pkg-config --exists shaderc 2>/dev/null || need_shaderc=1
  pkg-config --exists spirv-cross-c-shared 2>/dev/null || need_spirv=1
  if [[ "$need_shaderc" == 0 && "$need_spirv" == 0 ]]; then
    echo "ok shaderc $(pkg-config --modversion shaderc 2>/dev/null || echo found) + spirv-cross (Win7 D3D11)"
    return 0
  fi
  need git
  need cmake
  need ninja
  mkdir -p "$BUILD_DIR" "$PREFIX"
  local w7cflags
  w7cflags="$(kotv_windows_mpv_cflags)"

  if [[ "$need_spirv" == 1 ]]; then
    local tag="${KOTV_SPIRV_CROSS_TAG:-vulkan-sdk-1.3.296.0}"
    echo "==> build SPIRV-Cross $tag (shared, Win7 D3D11)"
    cd "$BUILD_DIR"
    if [[ ! -d SPIRV-Cross/.git ]]; then
      git clone --depth 1 --branch "$tag" https://github.com/KhronosGroup/SPIRV-Cross.git SPIRV-Cross \
        || git clone --depth 1 https://github.com/KhronosGroup/SPIRV-Cross.git SPIRV-Cross
    fi
    rm -rf SPIRV-Cross/build
    cmake -S SPIRV-Cross -B SPIRV-Cross/build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="$PREFIX" \
      -DCMAKE_C_FLAGS="$w7cflags" \
      -DCMAKE_CXX_FLAGS="$w7cflags" \
      -DSPIRV_CROSS_SHARED=ON \
      -DSPIRV_CROSS_STATIC=OFF \
      -DSPIRV_CROSS_CLI=OFF \
      -DSPIRV_CROSS_ENABLE_TESTS=OFF
    cmake --build SPIRV-Cross/build -j"$JOBS"
    cmake --install SPIRV-Cross/build
  fi

  if [[ "$need_shaderc" == 1 ]]; then
    local stag="${KOTV_SHADERC_TAG:-v2024.1}"
    echo "==> build shaderc $stag (static, Win7 D3D11)"
    cd "$BUILD_DIR"
    if [[ ! -d shaderc/.git ]]; then
      git clone --depth 1 --branch "$stag" https://github.com/google/shaderc.git shaderc \
        || git clone --depth 1 https://github.com/google/shaderc.git shaderc
    fi
    if [[ ! -f shaderc/third_party/glslang/CMakeLists.txt ]]; then
      (cd shaderc && python3 ./utils/git-sync-deps) \
        || (cd shaderc && python ./utils/git-sync-deps)
    fi
    # GCC15：glslang SpvBuilder.h 用 uint32_t 却未 include cstdint
    local hdr="shaderc/third_party/glslang/SPIRV/SpvBuilder.h"
    if [[ -f "$hdr" ]] && ! grep -q '#include <cstdint>' "$hdr"; then
      if command -v python3 >/dev/null; then
        python3 - "$hdr" <<'PY'
import sys
p = sys.argv[1]
t = open(p, encoding='utf-8', errors='replace').read()
if '#include <cstdint>' not in t:
    t = t.replace('#include <algorithm>', '#include <cstdint>\n#include <algorithm>', 1)
    if '#include <cstdint>' not in t:
        t = '#include <cstdint>\n' + t
    open(p, 'w', encoding='utf-8').write(t)
print('patched', p, 'for cstdint')
PY
      fi
    fi
    rm -rf shaderc/build
    # -include cstdint：兜底 MinGW/GCC15 对第三方头的严格性
    cmake -S shaderc -B shaderc/build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="$PREFIX" \
      -DCMAKE_C_FLAGS="$w7cflags" \
      -DCMAKE_CXX_FLAGS="$w7cflags -include cstdint" \
      -DBUILD_SHARED_LIBS=OFF \
      -DSHADERC_SKIP_TESTS=ON \
      -DSHADERC_SKIP_EXAMPLES=ON \
      -DSHADERC_SKIP_COPYRIGHT_CHECK=ON
    cmake --build shaderc/build -j"$JOBS"
    cmake --install shaderc/build
  fi

  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  pkg-config --exists spirv-cross-c-shared \
    || { echo "ERROR: spirv-cross-c-shared not visible to pkg-config after build" >&2; exit 1; }
  pkg-config --exists shaderc \
    || { echo "ERROR: shaderc not visible to pkg-config after build" >&2; ls -la "$PREFIX/lib/pkgconfig" >&2; exit 1; }
  echo "ok Win7 D3D11 deps: shaderc=$(pkg-config --modversion shaderc) spirv-cross=$(pkg-config --modversion spirv-cross-c-shared 2>/dev/null || echo ok)"
}

ensure_windows_vulkan() {
  if kotv_is_mpv_win7_build; then
    echo "skip VULKAN_SDK (Win7 D3D11-only libmpv build)"
    return 0
  fi
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
  kotv_meson_compile build "mpv-linux"
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
  kotv_meson_compile build "mpv-macos"
  cp -f build/libmpv.dylib "$ASSET/macos/libmpv.dylib"
  if strings "$ASSET/macos/libmpv.dylib" | grep -q 'AVFFrameReceiver'; then
    echo "ERROR: libmpv still contains AVFFrameReceiver (rebuild FFmpeg with --disable-avdevice)" >&2
    exit 1
  fi
  if [[ "$AV3A" == "1" ]]; then
    grep -aqE 'libarcdav3a|AV3A Audio Vivid' "$ASSET/macos/libmpv.dylib" \
      || { echo "ERROR: libmpv.dylib missing AV3A symbols" >&2; exit 1; }
  fi
  echo "built macOS/libmpv.dylib (+ AV3A=$AV3A, no avdevice)"
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
  ensure_windows_d3d11_shader_deps
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
  # libplacebo / mpv 的 meson 都要能找到 pkg-config；必须在 ensure_libplacebo 之前写好。
  mkdir -p "$BUILD_DIR"
  cat >"$BUILD_DIR/meson-native-kotv.ini" <<EOF
[binaries]
pkg-config = '$pc_win'
pkgconfig = '$pc_win'

[built-in options]
pkg_config_path = '$pkg_win'
EOF
  ensure_libplacebo

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
  if kotv_is_windows_build; then
    apply_mpv_win7_patches
    export CFLAGS="${CFLAGS:-} $(kotv_windows_mpv_cflags)"
    export CXXFLAGS="${CXXFLAGS:-} $(kotv_windows_mpv_cflags)"
    export LDFLAGS="${LDFLAGS:-} -Wl,--subsystem,windows:6.01"
  fi
  rm -rf build
  # meson-native-kotv.ini 已在 ensure_libplacebo 前写入
  if kotv_is_windows_build; then
    local mpv_vk=enabled
    kotv_is_mpv_win7_build && mpv_vk=disabled
    if kotv_is_mpv_win7_build; then
      echo "==> mpv Win7 build: vulkan=disabled, d3d11=enabled (vo=gpu + D3D11/OpenGL/auto)"
    fi
    local -a mpv_extra=()
    if kotv_is_mpv_win7_build; then
      mpv_extra+=(-Dd3d11=enabled -Dshaderc=enabled -Dspirv-cross=enabled)
    fi
    meson setup build \
      --native-file "$BUILD_DIR/meson-native-kotv.ini" \
      --buildtype=release \
      -Db_ndebug=true \
      -Ddefault_library=shared \
      -Dlibmpv=true \
      -Dcplayer=false \
      -Dmanpage-build=disabled \
      -Dvulkan="$mpv_vk" \
      "${mpv_extra[@]}" \
      -Dlua=disabled \
      -Dc_args="['-D_WIN32_WINNT=0x0601','-DWINVER=0x0601','-DNTDDI_VERSION=0x06010000','-DNDEBUG']" \
      -Dcpp_args="['-D_WIN32_WINNT=0x0601','-DWINVER=0x0601','-DNTDDI_VERSION=0x06010000','-DNDEBUG']"
  else
    meson setup build \
      --native-file "$BUILD_DIR/meson-native-kotv.ini" \
      -Ddefault_library=shared \
      -Dlibmpv=true \
      -Dcplayer=false \
      -Dmanpage-build=disabled \
      -Dvulkan=enabled \
      -Dlua=disabled
  fi
  kotv_meson_compile build "mpv-windows"
  local out="$ASSET/windows/mpv-2.dll"
  local dll=""
  for cand in build/mpv-2.dll build/libmpv-2.dll build/libmpv.dll; do
    [[ -f "$cand" ]] && dll="$cand" && break
  done
  [[ -n "$dll" ]] || dll="$(find build -maxdepth 2 -name 'mpv-2.dll' -o -name 'libmpv-2.dll' 2>/dev/null | head -1 || true)"
  [[ -n "$dll" && -f "$dll" ]] || { echo "ERROR: mpv dll not found under build/" >&2; exit 1; }
  cp -f "$dll" "$out"
  verify_mpv_win7_imports "$out"
  harvest_windows_mpv_dlls
  if [[ "$AV3A" == "1" ]]; then
    grep -aqE 'libarcdav3a|AV3A Audio Vivid' "$out" \
      || { echo "ERROR: mpv-2.dll missing AV3A symbols" >&2; exit 1; }
  fi
  echo "built windows/mpv-2.dll (+ AV3A=$AV3A) from $dll"
  if kotv_is_mpv_win7_build; then
    # meson configure 摘要里 d3d11 应为 YES（依赖 shaderc+spirv-cross）
    if ! meson configure build 2>/dev/null | grep -Eiq '^[[:space:]]*d3d11[[:space:]]+(YES|true|enabled)'; then
      echo "ERROR: Win7 libmpv built without d3d11 (need shaderc+spirv-cross)" >&2
      meson configure build 2>/dev/null | grep -Ei 'd3d11|shaderc|spirv|vulkan' || true
      exit 1
    fi
    echo "ok Win7 mpv features include d3d11"
  fi
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
