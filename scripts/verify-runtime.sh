#!/usr/bin/env bash
# 校验发行 runtime 完整性（embed JVM/Python：要 libjvm/libpython + stdlib，不要依赖 java/python 启动器）
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

# 嵌套 runtime/runtime 一律失败
if [[ -d "$RT/runtime" ]]; then
  die "nested $RT/runtime detected (copy layout bug)"
fi

case "$PLAT" in
  macos-*)
    need_dir "$RT/jre/lib"
    need_file "$RT/jre/lib/libjli.dylib"
    need_file "$RT/jre/lib/server/libjvm.dylib"
    need_any_file \
      "$RT/python/lib/libpython3.14.dylib" \
      "$RT/python/lib/libpython3.14t.dylib" \
      "$RT/python/lib/libpython3.dylib"
    need_any_file "$RT/libvlc/libvlc.dylib" "$RT/libvlc/libvlc.5.dylib"
    ;;
  windows-*)
    need_dir "$RT/jre/lib"
    need_any_file "$RT/jre/lib/modules" "$RT/jre/lib/jrt-fs.jar"
    need_any_file "$RT/jre/bin/server/jvm.dll" "$RT/jre/bin/client/jvm.dll"
    # Win7 路径 API 垫片（JVM 依赖，仍需）
    if [[ "$PLAT" == "windows-x64" ]]; then
      need_file "$RT/jre/bin/api-ms-win-core-path-l1-1-0.dll"
    fi
    need_file "$RT/libvlc/libvlc.dll"

    need_any_file "$RT/python/python3.dll" "$RT/python/python314.dll" "$RT/python/python313.dll"
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
    need_dir "$RT/jre/lib"
    need_file "$RT/jre/lib/server/libjvm.so"
    need_any_file \
      "$RT/python/lib/libpython3.14.so" \
      "$RT/python/lib/libpython3.14t.so" \
      "$RT/python/lib/libpython3.so"
    need_any_file "$RT/libvlc/libvlc.so" "$RT/libvlc/libvlc.so.5"
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

# 发行包不应再带整包 VLC.app / 外部 mpv / 残留 libmpv（页内 MPV 由 Flutter media_kit 自带）
[[ ! -d "$RT/vlc" ]] || die "runtime/vlc must not ship (use libvlc/)"
[[ ! -d "$RT/mpv" ]] || die "runtime/mpv must not ship (Flutter media_kit / outie#mpv)"
[[ ! -d "$RT/libmpv" ]] || die "runtime/libmpv must not ship (Flutter media_kit bundles libmpv)"

# embed：发行包不得再带 java/python 启动器。
# prepare-runtime 本地树可以保留启动器（装 wheel 等）；package/bundle 后设 KOTV_EXPECT_EMBED_STRIP=1。
if [[ "${KOTV_EXPECT_EMBED_STRIP:-}" == "1" ]]; then
  forbid_file() { [[ ! -e "$1" ]] || die "must not ship launcher: $1"; }
  forbid_file "$RT/jre/bin/java"
  forbid_file "$RT/jre/bin/java.exe"
  forbid_file "$RT/jre/bin/javaw"
  forbid_file "$RT/jre/bin/javaw.exe"
  forbid_file "$RT/python/bin/python"
  forbid_file "$RT/python/bin/python3"
  forbid_file "$RT/python/python.exe"
  forbid_file "$RT/python/python3.exe"
  forbid_file "$RT/python/pythonw.exe"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "verify-runtime FAILED for $PLAT at $RT" >&2
  exit 1
fi
echo "verify-runtime OK: $PLAT (jre=$jre_files files, jre/lib=$jre_lib_files files, embed-jvm/py${KOTV_EXPECT_EMBED_STRIP:+, stripped})"
