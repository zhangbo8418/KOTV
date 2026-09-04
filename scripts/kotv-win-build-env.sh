#!/usr/bin/env bash
# Windows MinGW 构建用：去掉带空格 PATH，同时保留 cmake/ninja（装在 Program Files）。
# 由 ensure-desktop-*.sh / ffmpeg 脚本 source。
# shellcheck shell=bash

kotv_is_windows_build() {
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
  esac
  [[ "${OS:-}" == "Windows_NT" ]]
}

kotv_win7_cflags() {
  printf '%s' "-D_WIN32_WINNT=0x0601 -DWINVER=0x0601 -DNTDDI_VERSION=0x06010000"
}

# 在清理 PATH 前记下 cmake/ninja 绝对路径，写无空格包装器到 $1/bin。
kotv_ensure_win_cmake_wrappers() {
  local bindir="${1:?bindir}"
  kotv_is_windows_build || return 0
  mkdir -p "$bindir"
  local cmake_bin ninja_bin c
  cmake_bin="$(command -v cmake 2>/dev/null || true)"
  if [[ -z "$cmake_bin" || "$cmake_bin" == *[\ ]* ]]; then
    for c in \
      "/c/Program Files/CMake/bin/cmake.exe" \
      "/c/Program Files (x86)/CMake/bin/cmake.exe" \
      "/c/Program Files/Microsoft Visual Studio/2022/Enterprise/Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe"; do
      [[ -x "$c" ]] && cmake_bin="$c" && break
    done
  fi
  if [[ -n "$cmake_bin" && -x "$cmake_bin" ]]; then
    # 用 cmd 风格路径写进包装器，避免 bash 再解析空格
    local cmake_win="$cmake_bin"
    if command -v cygpath >/dev/null 2>&1; then
      cmake_win="$(cygpath -m "$cmake_bin")"
    fi
    cat >"$bindir/cmake" <<EOF
#!/bin/bash
exec "$cmake_bin" "\$@"
EOF
    chmod +x "$bindir/cmake"
    # 同步 .exe 名给偶发调用
    cp -f "$bindir/cmake" "$bindir/cmake.exe" 2>/dev/null || true
    echo "ok cmake wrapper → $bindir/cmake ($cmake_win)"
  fi
  ninja_bin="$(command -v ninja 2>/dev/null || true)"
  if [[ -z "$ninja_bin" || "$ninja_bin" == *[\ ]* ]]; then
    for c in \
      "/c/Program Files/Microsoft Visual Studio/2022/Enterprise/Common7/IDE/CommonExtensions/Microsoft/CMake/Ninja/ninja.exe" \
      "/c/ProgramData/chocolatey/bin/ninja.exe"; do
      [[ -x "$c" ]] && ninja_bin="$c" && break
    done
  fi
  if [[ -n "$ninja_bin" && -x "$ninja_bin" ]]; then
    cat >"$bindir/ninja" <<EOF
#!/bin/bash
exec "$ninja_bin" "\$@"
EOF
    chmod +x "$bindir/ninja"
  fi
}

kotv_clean_win_path() {
  kotv_is_windows_build || return 0
  local root_bin="${1:-}"
  # 先落包装器（此时 PATH 里还能看到 Program Files 的 cmake）
  if [[ -n "$root_bin" ]]; then
    kotv_ensure_win_cmake_wrappers "$root_bin"
  fi
  export PATH="/c/mingw-msvcrt/mingw64/bin:/usr/bin:/bin:${PATH:-}"
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
  export CC="${CC:-gcc}" CXX="${CXX:-g++}"
  export CFLAGS="${CFLAGS:-} $(kotv_win7_cflags)"
  export CXXFLAGS="${CXXFLAGS:-} $(kotv_win7_cflags)"
  if ! command -v cmake >/dev/null 2>&1; then
    echo "ERROR: cmake not found after PATH clean (need Program Files CMake wrapper)" >&2
    exit 1
  fi
  echo "ok win PATH cleaned; cmake=$(command -v cmake)"
}
