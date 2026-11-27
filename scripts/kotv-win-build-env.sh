#!/usr/bin/env bash
# 构建脚本共用函数：命令检查、sha256 校验、Windows MinGW 路径与 PATH 清理、macOS 目标 arch。
# 由 build-*.sh / ensure-desktop-*.sh source；只定义函数，无副作用。
# shellcheck shell=bash

kotv_is_windows_build() {
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
  esac
  [[ "${OS:-}" == "Windows_NT" ]]
}

# Windows ARM64：MINGW64 下 uname -m 常谎报 x86_64；以 OS 串 / PROCESSOR_* 为准。
# 不用 CC -dumpmachine：PATH 上的 gcc 可能仍是 x86_64，会误判宿主架构。
kotv_windows_is_arm64() {
  kotv_is_windows_build || return 1
  local os m pa pa64
  os="$(uname -s 2>/dev/null || true)"
  m="$(uname -m 2>/dev/null || true)"
  pa="${PROCESSOR_ARCHITECTURE:-}"
  pa64="${PROCESSOR_ARCHITEW6432:-}"
  case "$m" in ARM64|arm64|aarch64) return 0 ;; esac
  [[ "$os" == *ARM64* || "$os" == *aarch64* ]] && return 0
  [[ "$pa" == "ARM64" || "$pa64" == "ARM64" ]] && return 0
  return 1
}

# windows-arm64 | windows-x64
kotv_windows_plat() {
  if kotv_windows_is_arm64; then echo windows-arm64; else echo windows-x64; fi
}

# 本机发行平台标签（darwin/linux/windows）。Windows 走 kotv_windows_plat。
kotv_detect_host_plat() {
  local os m
  os="$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  m="$(uname -m 2>/dev/null || true)"
  case "$os" in
    darwin)
      [[ "$m" == "arm64" ]] && echo macos-arm64 || echo macos-x64
      ;;
    linux)
      [[ "$m" == "aarch64" || "$m" == "arm64" ]] && echo linux-arm64 || echo linux-x64
      ;;
    mingw*|msys*|cygwin*)
      kotv_windows_plat
      ;;
    *)
      echo "unsupported OS: $os" >&2
      return 1
      ;;
  esac
}

# MinGW 三元组：aarch64-w64-mingw32 | x86_64-w64-mingw32
kotv_windows_triplet() {
  if kotv_windows_is_arm64; then echo aarch64-w64-mingw32; else echo x86_64-w64-mingw32; fi
}

# Rust MinGW target：arm64 用 llvm-mingw → gnullvm（rustc 无 aarch64-pc-windows-gnu）；
# x86_64 仍用经典 gnu。
kotv_windows_rust_gnu_target() {
  if kotv_windows_is_arm64; then echo aarch64-pc-windows-gnullvm; else echo x86_64-pc-windows-gnu; fi
}

# OpenSSL Configure 目标：mingwarm64（OpenSSL ≥3.6）| mingw64
kotv_windows_openssl_target() {
  if kotv_windows_is_arm64; then echo mingwarm64; else echo mingw64; fi
}

# LunarG Vulkan SDK 安装器架构段：ARM64 | X64
kotv_windows_vulkan_arch() {
  if kotv_windows_is_arm64; then echo ARM64; else echo X64; fi
}

# x86_64 才把 mingw-msvcrt 前置；arm64 保留 PATH 上的 llvm-mingw，避免抢成 x86_64 gcc。
kotv_windows_prefer_msvcrt_mingw() {
  kotv_is_windows_build || return 0
  kotv_windows_is_arm64 && return 0
  [[ -d "/c/mingw-msvcrt/mingw64/bin" ]] || return 0
  export PATH="/c/mingw-msvcrt/mingw64/bin:$PATH"
}

# 导出 Windows 本机 C/C++ 工具链（ffmpeg / mpv / codecs 等）。
# arm64：llvm-mingw 前缀 clang/gcc。x86_64：沿用 PATH 上的 gcc（CI 已前置 mingw-msvcrt），
# 勿抢成其它前缀的 x86_64-w64-mingw32-gcc（可能来自不完整工具链）。
kotv_windows_export_cc() {
  kotv_is_windows_build || return 0
  local t
  t="$(kotv_windows_triplet)"
  if kotv_windows_is_arm64; then
    if command -v "${t}-clang" >/dev/null 2>&1; then
      export CC="${CC:-${t}-clang}"
      export CXX="${CXX:-${t}-clang++}"
    elif command -v "${t}-gcc" >/dev/null 2>&1; then
      export CC="${CC:-${t}-gcc}"
      export CXX="${CXX:-${t}-g++}"
    else
      export CC="${CC:-gcc}"
      export CXX="${CXX:-g++}"
    fi
    if command -v "${t}-ar" >/dev/null 2>&1; then
      export AR="${AR:-${t}-ar}"
    fi
  else
    export CC="${CC:-gcc}"
    export CXX="${CXX:-g++}"
  fi
}

# Go CGO（windows/arm64）：必须用 aarch64-w64-mingw32-clang；x86_64 gcc 会在 gcc_arm64.S 失败。
kotv_windows_export_cgo_arm64() {
  if command -v aarch64-w64-mingw32-clang >/dev/null 2>&1; then
    export CC=aarch64-w64-mingw32-clang
    export CXX="${CXX:-aarch64-w64-mingw32-clang++}"
  fi
  if [[ -z "${CC:-}" ]] || ! command -v "${CC}" >/dev/null 2>&1; then
    echo "ERROR: windows-arm64 CGO 需要 aarch64-w64-mingw32-clang（llvm-mingw）" >&2
    return 1
  fi
  if "$CC" --version 2>&1 | head -5 | grep -qiE 'x86_64-w64-mingw32|Target: x86_64'; then
    echo "ERROR: CC=$CC 是 x86_64 工具链，无法编 windows/arm64 CGO" >&2
    return 1
  fi
  export CGO_CFLAGS="${CGO_CFLAGS:--O2}"
  export CGO_CXXFLAGS="${CGO_CXXFLAGS:--O2}"
  echo "[cgo] windows-arm64 CC=$CC CXX=${CXX:-}"
}

# Cargo/cargo-c：为当前 Windows arch 设置 gnu target 与 linker 环境变量。
kotv_windows_export_cargo_gnu() {
  kotv_is_windows_build || return 0
  local target key upper
  target="$(kotv_windows_rust_gnu_target)"
  kotv_windows_export_cc
  key="${target//-/_}"
  export "CC_${key}=${CC}"
  export "CXX_${key}=${CXX}"
  export "AR_${key}=${AR:-ar}"
  # 分两步 tr：部分环境对 '[:lower:]-' 一类字符集不友好。
  upper="$(printf '%s' "$target" | tr '-' '_' | tr '[:lower:]' '[:upper:]')"
  export "CARGO_TARGET_${upper}_LINKER=${CC}"
  export CARGO_BUILD_TARGET="$target"
}

# FFmpeg configure 的 Windows --target-os / --arch（逐行输出，供 mapfile / while read）。
kotv_windows_ffmpeg_arch_args() {
  if kotv_windows_is_arm64; then
    # 显式 aarch64：否则 MINGW64 谎报时会开 x86 emms/nasm。
    printf '%s\n' --target-os=mingw32 --arch=aarch64 --disable-x86asm
  else
    printf '%s\n' --target-os=mingw64 --arch=x86_64
  fi
}

# macOS 应用的最低系统版本：取 Xcode 工程里的 MACOSX_DEPLOYMENT_TARGET（随包 dylib 须不高于它）。
kotv_macos_deployment_target() {
  local root
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  sed -n 's/.*MACOSX_DEPLOYMENT_TARGET = \([0-9.]*\);.*/\1/p' \
    "$root/flutter/macos/Runner.xcodeproj/project.pbxproj" | sort -u -V | tail -1
}

# 缺命令就退出。
need() { command -v "$1" >/dev/null || { echo "need $1" >&2; exit 1; }; }

# Windows 下把 MSYS 路径转成 C:/… 形式（给 CMake / meson 用）；其它平台原样输出。
kotv_native_path() {
  local p="$1"
  if kotv_is_windows_build && command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$p"
  else
    printf '%s' "$p"
  fi
}

# 校验 sha256；本机既没有 shasum 也没有 sha256sum 时放行。
kotv_verify_sha256() {
  local f="$1" expect="$2"
  if command -v shasum >/dev/null; then
    echo "$expect  $f" | shasum -a 256 -c -
  elif command -v sha256sum >/dev/null; then
    echo "$expect  $f" | sha256sum -c -
  else
    return 0
  fi
}

# 标准输入的 sha256 前 12 位，作缓存标记（Windows Git Bash 只有 sha256sum）。
kotv_sha256_short() {
  if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi | cut -c1-12
}

kotv_win7_cflags() {
  printf '%s' "-D_WIN32_WINNT=0x0601 -DWINVER=0x0601 -DNTDDI_VERSION=0x06010000"
}

# macOS 目标 arch（交叉编由 KOTV_MPV_MACOS_ARCH 指定）。
kotv_macos_target_arch() {
  echo "${KOTV_MPV_MACOS_ARCH:-$(uname -m 2>/dev/null || echo)}"
}

# 真实硬件 arch。arch -x86_64 / Rosetta 下 uname -m 会谎报成 x86_64。
kotv_macos_hw_arch() {
  if [[ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" == "1" ]]; then
    echo arm64
  else
    uname -m 2>/dev/null || echo
  fi
}

# 给 CMake 追加 -DCMAKE_OSX_ARCHITECTURES=…（非 Darwin 无输出）。
kotv_cmake_macos_arch_args() {
  [[ "$(uname -s 2>/dev/null)" == "Darwin" ]] || return 0
  printf '%s\n' "-DCMAKE_OSX_ARCHITECTURES=$(kotv_macos_target_arch)"
}

# 导出 macOS 目标 -arch 进 CFLAGS/CXXFLAGS/LDFLAGS（非 Darwin 无操作）。
kotv_macos_export_arch_flags() {
  [[ "$(uname -s 2>/dev/null)" == "Darwin" ]] || return 0
  local arch
  arch="$(kotv_macos_target_arch)"
  export CFLAGS="${CFLAGS:-} -arch ${arch}"
  export CXXFLAGS="${CXXFLAGS:-} -arch ${arch}"
  export LDFLAGS="${LDFLAGS:-} -arch ${arch}"
}

# 写出 meson native-file（强制目标 arch），打印路径。
# $1=输出目录；$2=可选 PREFIX（写入 pkg_config_path）。
kotv_macos_write_meson_native_file() {
  [[ "$(uname -s 2>/dev/null)" == "Darwin" ]] || return 1
  local outdir="${1:?outdir}" prefix="${2:-}" arch cpu_family ini pkg_line=""
  arch="$(kotv_macos_target_arch)"
  cpu_family="$arch"
  [[ "$arch" == "arm64" ]] && cpu_family="aarch64"
  mkdir -p "$outdir"
  ini="$outdir/meson-native-macos-${arch}.ini"
  if [[ -n "$prefix" ]]; then
    pkg_line="pkg_config_path = '${prefix}/lib/pkgconfig'"
  fi
  cat >"$ini" <<EOF
[binaries]
c = ['clang', '-arch', '$arch']
cpp = ['clang++', '-arch', '$arch']
objc = ['clang', '-arch', '$arch']
objcpp = ['clang++', '-arch', '$arch']
ar = 'ar'
strip = 'strip'
pkg-config = 'pkg-config'
pkgconfig = 'pkg-config'

[built-in options]
c_args = ['-arch', '$arch']
cpp_args = ['-arch', '$arch']
objc_args = ['-arch', '$arch']
objcpp_args = ['-arch', '$arch']
c_link_args = ['-arch', '$arch']
cpp_link_args = ['-arch', '$arch']
${pkg_line}

[host_machine]
system = 'darwin'
cpu_family = '$cpu_family'
cpu = '$arch'
endian = 'little'
EOF
  printf '%s\n' "$ini"
}

# Windows CMake 生成器：统一 MinGW Makefiles。
# 勿用 Ninja 同时塞 CMAKE_MAKE_PROGRAM=mingw32-make——CMake 会把 `make -v` 当成 ninja 版本而失败。
kotv_windows_cmake_generator() {
  echo "MinGW Makefiles"
}

# Windows CMake：使用当前 CC/CXX（须先 kotv_windows_export_cc / clean_win_path）。
kotv_windows_cmake_compiler_args() {
  kotv_is_windows_build || return 0
  [[ -n "${CC:-}" ]] || kotv_windows_export_cc
  printf '%s\n' "-DCMAKE_C_COMPILER=${CC}"
  [[ -n "${CXX:-}" ]] && printf '%s\n' "-DCMAKE_CXX_COMPILER=${CXX}"
  if command -v mingw32-make >/dev/null 2>&1; then
    printf '%s\n' "-DCMAKE_MAKE_PROGRAM=mingw32-make"
  fi
}

# dylib/可执行文件是否含目标 arch（lipo）。
kotv_macos_file_has_arch() {
  local f="$1" want="$2" archs
  [[ -f "$f" && -n "$want" ]] || return 1
  archs="$(lipo -archs "$f" 2>/dev/null || true)"
  [[ -n "$archs" ]] || return 1
  case " $archs " in
    *" $want "*) return 0 ;;
  esac
  return 1
}

# 在清理 PATH 前记下 cmake/ninja 绝对路径，写无空格包装器到 $1/bin。
# 注意：必须始终解析「真实」cmake.exe。若 PATH 已含 $bindir/cmake，
# command -v 会命中自有包装器，再写成 exec 自身 → 无限递归（CI 卡数小时无输出）。
kotv_ensure_win_cmake_wrappers() {
  local bindir="${1:?bindir}"
  kotv_is_windows_build || return 0
  mkdir -p "$bindir"
  local cmake_bin="" c

  # 1) 永远优先 Program Files 真实 cmake（勿信任 PATH 上的自有 wrapper）
  for c in \
    "/c/Program Files/CMake/bin/cmake.exe" \
    "/c/Program Files (x86)/CMake/bin/cmake.exe" \
    "/c/Program Files/Microsoft Visual Studio/2022/Enterprise/Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe"; do
    [[ -x "$c" ]] && cmake_bin="$c" && break
  done

  # 2) 回退 command -v，但拒绝 bindir 内入口 / shebang 脚本
  if [[ -z "$cmake_bin" ]]; then
    c="$(command -v cmake 2>/dev/null || true)"
    case "$c" in
      "$bindir"/cmake|"$bindir"/cmake.exe) c="" ;;
    esac
    if [[ -n "$c" && -f "$c" ]] && head -n1 "$c" 2>/dev/null | grep -q '^#!'; then
      c=""
    fi
    [[ -n "$c" && -x "$c" ]] && cmake_bin="$c"
  fi

  if [[ -z "$cmake_bin" || ! -x "$cmake_bin" ]]; then
    echo "ERROR: real cmake.exe not found for wrapper" >&2
    return 1
  fi

  local cmake_win="$cmake_bin"
  if command -v cygpath >/dev/null 2>&1; then
    cmake_win="$(cygpath -m "$cmake_bin")"
  fi
  cat >"$bindir/cmake" <<EOF
#!/bin/bash
exec "$cmake_bin" "\$@"
EOF
  chmod +x "$bindir/cmake"
  # 勿把 bash 脚本伪装成 cmake.exe（CreateProcess 会踩坑；也可能自指递归）
  rm -f "$bindir/cmake.exe"
  echo "ok cmake wrapper → $bindir/cmake ($cmake_win)"

  # 不在无空格 PATH 里包一层 ninja：MinGW CMake + 包装器常报 unknown error。
  # Windows 构建统一用 MinGW Makefiles。
  rm -f "$bindir/ninja" "$bindir/ninja.exe" 2>/dev/null || true
}

kotv_clean_win_path() {
  kotv_is_windows_build || return 0
  local root_bin="${1:-}"
  # 先落包装器（此时 PATH 里还能看到 Program Files 的 cmake）
  if [[ -n "$root_bin" ]]; then
    kotv_ensure_win_cmake_wrappers "$root_bin"
  fi
  # arm64：勿前置 x86_64 mingw-msvcrt，保留 llvm-mingw。
  if kotv_windows_is_arm64; then
    export PATH="/usr/bin:/bin:${PATH:-}"
  else
    export PATH="/c/mingw-msvcrt/mingw64/bin:/usr/bin:/bin:${PATH:-}"
  fi
  if [[ -n "$root_bin" ]]; then
    export PATH="$root_bin:$PATH"
  fi
  local cleaned="" part
  IFS=':' read -ra _p <<<"$PATH"
  for part in "${_p[@]}"; do
    case "$part" in
      *[\ ]*|*[Pp]rogram*[Ff]iles*) continue ;;
    esac
    [[ -z "$cleaned" ]] && cleaned="$part" || cleaned="$cleaned:$part"
  done
  export PATH="$cleaned"
  kotv_windows_export_cc
  export CFLAGS="${CFLAGS:-} $(kotv_win7_cflags)"
  export CXXFLAGS="${CXXFLAGS:-} $(kotv_win7_cflags)"
  if ! command -v cmake >/dev/null 2>&1; then
    echo "ERROR: cmake not found after PATH clean (need Program Files CMake wrapper)" >&2
    exit 1
  fi
  echo "ok win PATH cleaned; cmake=$(command -v cmake) CC=${CC:-}"
}
