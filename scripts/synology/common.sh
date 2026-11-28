#!/usr/bin/env bash
# 群晖 Toolkit 共用：平台映射、sysroot / 交叉编译器、并行调度、引擎校验。
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

# 多任务并行时均分 make/ninja -j，避免 N 路各占满核
# 用法: kotv_syno_jobs_budget <并行任务数>
kotv_syno_jobs_budget() {
  local n="${1:-1}" total
  total="$(kotv_syno_njobs)"
  if [[ "$n" -lt 1 ]]; then n=1; fi
  local per=$(( total / n ))
  if [[ "$per" -lt 1 ]]; then per=1; fi
  echo "$per"
}

# 并行跑若干命令；任一失败则整体失败。日志前缀为任务名。
# 用法: kotv_syno_parallel "name1:cmd1" "name2:cmd2" ...
# cmd 在当前 shell 函数可见范围内执行（需 export -f 或外部脚本）。
kotv_syno_parallel() {
  local -a specs=("$@")
  local -a pids=() names=()
  local i spec name cmd logdir rc=0 pid
  if [[ ${#specs[@]} -eq 0 ]]; then
    return 0
  fi
  logdir="${KOTV_SYNO_PARALLEL_LOGDIR:-$(kotv_syno_root)/.syno-build/parallel-logs}"
  mkdir -p "$logdir"
  echo "==> parallel (${#specs[@]}): ${specs[*]%%:*}"
  for spec in "${specs[@]}"; do
    name="${spec%%:*}"
    cmd="${spec#*:}"
    if [[ -z "$name" || "$name" == "$spec" || -z "$cmd" ]]; then
      echo "ERROR: kotv_syno_parallel want name:command, got: $spec" >&2
      return 1
    fi
    names+=("$name")
    (
      set -euo pipefail
      echo "[$name] start"
      # shellcheck disable=SC2086
      eval "$cmd"
    ) >"$logdir/${name}.log" 2>&1 &
    pids+=("$!")
  done
  for i in "${!pids[@]}"; do
    pid="${pids[$i]}"
    name="${names[$i]}"
    if wait "$pid"; then
      echo "[$name] ok"
      # 成功时只回显末尾，减少 CI 刷屏；失败时整份日志
      tail -n 40 "$logdir/${name}.log" 2>/dev/null || true
    else
      rc=1
      echo "[$name] FAILED (see $logdir/${name}.log)" >&2
      cat "$logdir/${name}.log" >&2 || true
    fi
  done
  return "$rc"
}

# 断言引擎为 Toolkit 动态链 glibc（交叉产物勿用宿主 ldd 判定）
kotv_syno_assert_dynamic_engine() {
  local eng="$1"
  local info
  if [[ ! -x "$eng" ]]; then
    echo "ERROR: missing engine: $eng" >&2
    return 1
  fi
  info="$(file -b "$eng" 2>/dev/null || true)"
  case "$info" in
    *statically\ linked*)
      echo "ERROR: engine is statically linked; Synology SPK needs Toolkit dynamic engine" >&2
      echo "$info" >&2
      return 1
      ;;
  esac
  if [[ "$info" != *"dynamically linked"* ]]; then
    echo "ERROR: expected dynamically linked engine, got: ${info:-unknown}" >&2
    return 1
  fi
  if [[ "$info" == *musl* ]]; then
    echo "ERROR: musl-linked engine not allowed for Synology SPK" >&2
    return 1
  fi
  if command -v readelf >/dev/null 2>&1; then
    if ! readelf -l "$eng" 2>/dev/null | grep -q 'INTERP'; then
      echo "ERROR: engine missing INTERP (not a dynamic ELF)" >&2
      return 1
    fi
    echo "engine dynamic deps (readelf):"
    readelf -d "$eng" 2>/dev/null | grep -E 'NEEDED|Shared library' | head -20 || true
  fi
  return 0
}
