#!/usr/bin/env bash
# 群晖 Toolkit 共用：平台映射、sysroot / 交叉编译器、组件清单、引擎校验。
# 由其它 scripts/synology/*.sh source，勿直接执行。
# shellcheck shell=bash

kotv_syno_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

kotv_syno_load_versions() {
  # shellcheck source=versions.env
  source "$(kotv_syno_root)/scripts/synology/versions.env"
}

# geminilake|rtd1296 → 打印: arch_label goarch target_cpu
kotv_syno_plat_meta() {
  case "$1" in
    geminilake) echo "x86_64 amd64 x64" ;;
    rtd1296)    echo "armv8 arm64 arm64" ;;
    *)
      echo "unsupported toolkit platform: $1 (want geminilake|rtd1296)" >&2
      return 1
      ;;
  esac
}

# Toolkit 运行时组件（CI 矩阵与本地 build-spk 共用）
kotv_syno_runtime_components() {
  echo "node python jre chromium ffmpeg"
}

# 是否在交叉编（Toolkit 目标 arch ≠ 宿主）
kotv_syno_is_cross() {
  case "$1" in
    rtd1296)
      local host
      host="$(uname -m 2>/dev/null || true)"
      [[ "$host" != "aarch64" && "$host" != "arm64" ]]
      ;;
    *) return 1 ;;
  esac
}

kotv_syno_toolkit_root() {
  echo "${KOTV_TOOLKIT_ROOT:-$(kotv_syno_root)/.toolkit}"
}

kotv_syno_env_dir() {
  local plat="$1" dsm="${2:-}"
  if [[ -z "$dsm" ]]; then
    kotv_syno_load_versions
    dsm="${SYNO_DSM_VER}"
  fi
  echo "$(kotv_syno_toolkit_root)/build_env/ds.${plat}-${dsm}"
}

# 在 EnvDeploy 目录下找 sysroot（勿回落到 env 根目录，否则会混进错误头文件）
# x86 Toolkit 常用 sys-root；armv8（rtd1296 等）常用 sysroot（无连字符）。
kotv_syno_find_sysroot() {
  local env_dir="$1" d
  for d in \
    "$env_dir/usr/local/x86_64-pc-linux-gnu/x86_64-pc-linux-gnu/sys-root" \
    "$env_dir/usr/local/x86_64-pc-linux-gnu/x86_64-pc-linux-gnu/sysroot" \
    "$env_dir/usr/local/aarch64-unknown-linux-gnu/aarch64-unknown-linux-gnu/sys-root" \
    "$env_dir/usr/local/aarch64-unknown-linux-gnu/aarch64-unknown-linux-gnu/sysroot" \
    "$env_dir/usr/local/aarch64-unknown-linux-gnueabi/aarch64-unknown-linux-gnueabi/sys-root" \
    "$env_dir/usr/local/aarch64-unknown-linux-gnueabi/aarch64-unknown-linux-gnueabi/sysroot" ; do
    if [[ -d "$d/usr/include" || -d "$d/usr/lib" || -d "$d/lib" ]]; then
      echo "$d"
      return 0
    fi
  done
  d="$(find "$env_dir/usr/local" \( -type d -name 'sys-root' -o -type d -name 'sysroot' \) 2>/dev/null | head -1 || true)"
  if [[ -n "$d" && ( -d "$d/usr/include" || -d "$d/usr/lib" || -d "$d/lib" ) ]]; then
    echo "$d"
    return 0
  fi
  echo "ERROR: sysroot/sys-root not found under $env_dir/usr/local" >&2
  find "$env_dir/usr/local" -maxdepth 2 -mindepth 1 -type d 2>/dev/null | head -40 >&2 || true
  return 1
}

# 找 Toolkit gcc；成功则 export CC CXX AR RANLIB STRIP SYSROOT 及 CFLAGS/LDFLAGS
kotv_syno_export_toolchain() {
  local env_dir="$1"
  local sysroot cc cxx ar ranlib strip_bin p
  sysroot="$(kotv_syno_find_sysroot "$env_dir")"

  cc=""
  for p in \
    "$env_dir/usr/local/x86_64-pc-linux-gnu/bin/x86_64-pc-linux-gnu-gcc" \
    "$env_dir/usr/local/aarch64-unknown-linux-gnu/bin/aarch64-unknown-linux-gnu-gcc" \
    "$env_dir/usr/local/aarch64-unknown-linux-gnueabi/bin/aarch64-unknown-linux-gnueabi-gcc" ; do
    if [[ -x "$p" ]]; then cc="$p"; break; fi
  done
  if [[ -z "$cc" ]]; then
    cc="$(find "$env_dir/usr/local" -type f -name '*-gcc' ! -name '*-gcc-*' 2>/dev/null | head -1 || true)"
  fi
  if [[ -z "$cc" || ! -x "$cc" ]]; then
    echo "ERROR: Toolkit gcc not found under $env_dir" >&2
    find "$env_dir/usr/local" -name '*gcc' 2>/dev/null | head -20 >&2 || true
    return 1
  fi
  cxx="${cc%gcc}g++"
  [[ -x "$cxx" ]] || cxx="${cc%-gcc}-g++"
  [[ -x "$cxx" ]] || cxx="$cc"
  ar="$(find "$(dirname "$cc")" -maxdepth 1 -type f -name '*-ar' 2>/dev/null | head -1 || true)"
  ranlib="$(find "$(dirname "$cc")" -maxdepth 1 -type f -name '*-ranlib' 2>/dev/null | head -1 || true)"
  strip_bin="$(find "$(dirname "$cc")" -maxdepth 1 -type f -name '*-strip' 2>/dev/null | head -1 || true)"

  export SYSROOT="$sysroot"
  export CC="$cc"
  export CXX="$cxx"
  export AR="${ar:-ar}"
  export RANLIB="${ranlib:-ranlib}"
  export STRIP="${strip_bin:-strip}"
  export CFLAGS="--sysroot=${SYSROOT} -O2 -pipe"
  export CXXFLAGS="--sysroot=${SYSROOT} -O2 -pipe"
  export LDFLAGS="--sysroot=${SYSROOT} -Wl,-O1"
  export CGO_CFLAGS="$CFLAGS"
  export CGO_CPPFLAGS="--sysroot=${SYSROOT}"
  export CGO_CXXFLAGS="$CXXFLAGS"
  export CGO_LDFLAGS="$LDFLAGS"
  export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
  export PKG_CONFIG_PATH="${SYSROOT}/usr/lib/pkgconfig:${SYSROOT}/usr/local/lib/pkgconfig"
  echo "toolchain CC=$CC SYSROOT=$SYSROOT"
}

# 宿主可用的并行度（可用 KOTV_SYNO_JOBS 覆盖）
kotv_syno_njobs() {
  echo "${KOTV_SYNO_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
}

# CI artifact 名：syno-{piece}-{arch|any}
kotv_syno_artifact_name() {
  local piece="$1" arch="${2:-any}"
  echo "syno-${piece}-${arch}"
}

# 断言引擎为全静态（无 INTERP / 宿主 ldd 解不出动态依赖）
kotv_syno_assert_static_engine() {
  local eng="$1"
  local info
  if [[ ! -x "$eng" ]]; then
    echo "ERROR: missing engine: $eng" >&2
    return 1
  fi
  info="$(file -b "$eng" 2>/dev/null || true)"
  if [[ "$info" == *"dynamically linked"* ]]; then
    echo "ERROR: expected statically linked engine, got: $info" >&2
    if command -v ldd >/dev/null 2>&1; then
      ldd "$eng" 2>&1 | head -20 >&2 || true
    fi
    return 1
  fi
  case "$info" in
    *statically\ linked*|*static*)
      echo "engine static OK: $info"
      ;;
    *)
      # 部分 file 版本对 musl 静态只报 ELF，再用 ldd / readelf 兜底
      if command -v ldd >/dev/null 2>&1 && ldd "$eng" >/dev/null 2>&1; then
        echo "ERROR: ldd resolved deps; not fully static: $info" >&2
        ldd "$eng" >&2 || true
        return 1
      fi
      if command -v readelf >/dev/null 2>&1 && readelf -l "$eng" 2>/dev/null | grep -q 'INTERP'; then
        echo "ERROR: engine has INTERP (dynamic): $info" >&2
        return 1
      fi
      echo "engine static OK (no dynamic INTERP): ${info:-unknown}"
      ;;
  esac
  return 0
}
