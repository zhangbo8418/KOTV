#!/usr/bin/env bash
# 群晖 Toolkit 共用：平台映射、sysroot / 交叉编译器探测。
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

# 在 EnvDeploy 目录下找 sysroot
kotv_syno_find_sysroot() {
  local env_dir="$1" d
  for d in \
    "$env_dir/usr/local/x86_64-pc-linux-gnu/x86_64-pc-linux-gnu/sys-root" \
    "$env_dir/usr/local/aarch64-unknown-linux-gnueabi/aarch64-unknown-linux-gnueabi/sys-root" \
    "$env_dir/usr/local/${1}-linux-gnu/"*"/sys-root" ; do
    if [[ -d "$d/usr/include" || -d "$d/usr/lib" ]]; then
      echo "$d"
      return 0
    fi
  done
  d="$(find "$env_dir/usr/local" -type d -name 'sys-root' 2>/dev/null | head -1 || true)"
  if [[ -n "$d" ]]; then
    echo "$d"
    return 0
  fi
  echo "$env_dir"
}

# 找 Toolkit gcc；成功则 export CC CXX AR RANLIB STRIP SYSROOT 及 CFLAGS/LDFLAGS
kotv_syno_export_toolchain() {
  local env_dir="$1"
  local sysroot cc cxx ar ranlib strip_bin p
  sysroot="$(kotv_syno_find_sysroot "$env_dir")"

  cc=""
  for p in \
    "$env_dir/usr/local/x86_64-pc-linux-gnu/bin/x86_64-pc-linux-gnu-gcc" \
    "$env_dir/usr/local/aarch64-unknown-linux-gnueabi/bin/aarch64-unknown-linux-gnueabi-gcc" ; do
    if [[ -x "$p" ]]; then cc="$p"; break; fi
  done
  if [[ -z "$cc" ]]; then
    cc="$(find "$env_dir/usr/local" -type f -name '*-gcc' 2>/dev/null | head -1 || true)"
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
  export CFLAGS="${CFLAGS:--O2 -pipe} --sysroot=${SYSROOT}"
  export CXXFLAGS="${CXXFLAGS:--O2 -pipe} --sysroot=${SYSROOT}"
  export LDFLAGS="${LDFLAGS:--Wl,-O1} --sysroot=${SYSROOT}"
  export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
  export PKG_CONFIG_PATH="${SYSROOT}/usr/lib/pkgconfig:${SYSROOT}/usr/local/lib/pkgconfig"
  echo "toolchain CC=$CC SYSROOT=$SYSROOT"
}
