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

# 嵌套 runtime/runtime 一律失败
if [[ -d "$RT/runtime" ]]; then
  die "nested $RT/runtime detected (copy layout bug)"
fi

case "$PLAT" in
  macos-*)
    need_file "$RT/jre/bin/java"
    need_dir "$RT/jre/lib"
    need_file "$RT/jre/lib/libjli.dylib"
    need_file "$RT/jre/lib/server/libjvm.dylib"
    need_any_file "$RT/python/bin/python3" "$RT/python/bin/python"
    if ! "$RT/jre/bin/java" -version >/dev/null 2>&1; then
      die "bundled java failed to start (check libjli / quarantine)"
    fi
    ;;
  windows-*)
    need_file "$RT/jre/bin/java.exe"
    need_dir "$RT/jre/lib"
    need_any_file "$RT/jre/lib/modules" "$RT/jre/lib/jrt-fs.jar"
    need_any_file "$RT/jre/bin/server/jvm.dll" "$RT/jre/bin/client/jvm.dll"
    # Win7 路径 API 垫片（缺则 Win7 上 java 起不来）
    if [[ "$PLAT" == "windows-x64" ]]; then
      need_file "$RT/jre/bin/api-ms-win-core-path-l1-1-0.dll"
    fi

    need_file "$RT/python/python.exe"
    need_dir "$RT/python/Lib/site-packages"
    need_dir "$RT/python/Lib/site-packages/requests"
    need_dir "$RT/python/Lib/site-packages/Crypto"
    need_dir "$RT/python/Lib/site-packages/urllib3"
    need_dir "$RT/python/Lib/site-packages/lxml"
    pth="$(find "$RT/python" -maxdepth 1 -name 'python*._pth' | head -1 || true)"
    if [[ -n "$pth" ]]; then
      grep -q 'site-packages' "$pth" || die "python ._pth missing Lib\\\\site-packages: $pth"
      grep -q '^import site' "$pth" || die "python ._pth missing 'import site': $pth"
    fi
    ;;
  linux-*)
    need_file "$RT/jre/bin/java"
    need_dir "$RT/jre/lib"
    need_file "$RT/jre/lib/server/libjvm.so"
    need_any_file "$RT/python/bin/python3" "$RT/python/bin/python"
    ;;
  *)
    die "unknown platform: $PLAT"
    ;;
esac

# JRE 过小通常意味着半包。注意：Liberica 21 的 lib/ 本就约十几个文件
# （modules 为 ~100MB 单体），不能用「lib 文件数 < 20」当半包信号。
jre_files="$(find "$RT/jre" -type f 2>/dev/null | wc -l | tr -d ' ')"
if [[ "${jre_files:-0}" -lt 100 ]]; then
  die "jre too incomplete: only ${jre_files} files (expected >=100)"
fi
need_any_file "$RT/jre/lib/modules" "$RT/jre/lib/jrt-fs.jar"
need_file "$RT/jre/lib/security/cacerts"
if [[ -f "$RT/jre/lib/modules" ]]; then
  modules_bytes="$(wc -c < "$RT/jre/lib/modules" | tr -d ' ')"
  # 完整 modules 通常数十 MB；过小多半是空文件/半下载
  if [[ "${modules_bytes:-0}" -lt 1000000 ]]; then
    die "jre/lib/modules too small: ${modules_bytes} bytes (Java bridge will EOF)"
  fi
fi
jre_lib_files="$(find "$RT/jre/lib" -type f 2>/dev/null | wc -l | tr -d ' ')"
if [[ "${jre_lib_files:-0}" -lt 10 ]]; then
  die "jre/lib too incomplete: only ${jre_lib_files} files (Java bridge will EOF)"
fi

# 发行包不应带外部播放器目录（页内原生 MPV 未打进 runtime；外部用系统安装）
[[ ! -d "$RT/mpv" ]] || die "runtime/mpv must not ship (native mpv / outie#mpv)"
[[ ! -d "$RT/libmpv" ]] || die "runtime/libmpv must not ship (page MPV is native, not runtime bundle)"
[[ ! -d "$RT/libvlc" ]] || die "runtime/libvlc must not ship"
[[ ! -d "$RT/vlc" ]] || die "runtime/vlc must not ship"

if [[ "$fail" -ne 0 ]]; then
  echo "verify-runtime FAILED for $PLAT at $RT" >&2
  exit 1
fi
echo "verify-runtime OK: $PLAT (jre=$jre_files files, jre/lib=$jre_lib_files files)"
