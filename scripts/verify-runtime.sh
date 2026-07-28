#!/usr/bin/env bash
# 校验发行 runtime 完整性（避免 JRE lib/ 丢失导致 Java bridge EOF）
# 用法: ./scripts/verify-runtime.sh <runtime-dir> <platform>
set -euo pipefail

RT="${1:?runtime dir}"
PLAT="${2:?platform}"

fail=0
die() { echo "ERROR: $*" >&2; fail=1; }
need_file() { [[ -f "$1" ]] || die "missing file: $1"; }
need_dir() { [[ -d "$1" ]] || die "missing dir: $1"; }
need_any_file() {
  local found=0 f
  for f in "$@"; do
    if [[ -f "$f" ]]; then found=1; break; fi
  done
  [[ "$found" -eq 1 ]] || die "missing any of: $*"
}

need_dir "$RT"
need_file "$RT/bridge/spider-bridge.jar"
need_dir "$RT/libvlc/plugins"
need_dir "$RT/libmpv"

case "$PLAT" in
  macos-*)
    need_file "$RT/jre/bin/java"
    need_file "$RT/jre/lib/libjli.dylib"
    need_file "$RT/jre/lib/server/libjvm.dylib"
    need_any_file "$RT/libvlc/libvlc.dylib" "$RT/libvlc/libvlc.5.dylib"
    need_any_file "$RT/libmpv/libmpv.dylib" "$RT/libmpv/libmpv.2.dylib" "$RT/libmpv/libmpv.1.dylib"
    # 冒烟：捆绑 java 能跑
    if ! "$RT/jre/bin/java" -version >/dev/null 2>&1; then
      die "bundled java failed to start (check libjli / quarantine)"
    fi
    ;;
  windows-*)
    need_file "$RT/jre/bin/java.exe"
    need_file "$RT/jre/bin/server/jvm.dll"
    need_file "$RT/libvlc/libvlc.dll"
    need_any_file "$RT/libmpv/libmpv-2.dll" "$RT/libmpv/mpv-2.dll" "$RT/libmpv/libmpv.dll"
    ;;
  linux-*)
    need_file "$RT/jre/bin/java"
    need_file "$RT/jre/lib/server/libjvm.so"
    need_any_file "$RT/libvlc/libvlc.so" "$RT/libvlc/libvlc.so.5"
    need_any_file "$RT/libmpv/libmpv.so" "$RT/libmpv/libmpv.so.2" "$RT/libmpv/libmpv.so.1"
    ;;
  *)
    die "unknown platform: $PLAT"
    ;;
esac

# JRE 过小通常意味着 lib/ 没拷全（曾导致 macOS .app 缺 libjli → bridge EOF）
jre_files="$(find "$RT/jre" -type f 2>/dev/null | wc -l | tr -d ' ')"
if [[ "${jre_files:-0}" -lt 100 ]]; then
  die "jre too incomplete: only ${jre_files} files (expected >=100)"
fi

# 发行包不应再带整包 VLC.app / 外部 mpv 可执行目录
[[ ! -d "$RT/vlc" ]] || die "runtime/vlc must not ship (use libvlc/)"
[[ ! -d "$RT/mpv" ]] || die "runtime/mpv must not ship (use libmpv/)"

if [[ "$fail" -ne 0 ]]; then
  echo "verify-runtime FAILED for $PLAT at $RT" >&2
  exit 1
fi
echo "verify-runtime OK: $PLAT ($jre_files jre files)"
