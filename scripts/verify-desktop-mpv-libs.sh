#!/usr/bin/env bash
# 校验桌面 libmpv 含 Vulkan + AV3A（源码编 FongMi）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSET="$ROOT/flutter/assets/mpv-libs"
fail=0

check_vulkan() {
  local f="$1"
  local name="$2"
  [[ -f "$f" ]] || { echo "skip $name (not built)"; return; }
  if grep -aqE 'vulkan|pl_vulkan|-Dvulkan=enabled' "$f" 2>/dev/null; then
    echo "ok $name: vulkan enabled"
  else
    echo "ERROR: $name lacks vulkan feature (rebuild with build-desktop-mpv-from-source.sh)" >&2
    fail=1
  fi
}

check_av3a() {
  local f="$1"
  local name="$2"
  [[ -f "$f" ]] || return
  if grep -aqE 'libarcdav3a|AV3A Audio Vivid|--enable-libarcdav3a' "$f" 2>/dev/null; then
    echo "ok $name: AV3A (libarcdav3a)"
  else
    echo "ERROR: $name lacks AV3A (desktop libmpv must be source-built with libarcdav3a)" >&2
    fail=1
  fi
}

check_no_avdevice() {
  local f="$1"
  local name="$2"
  [[ -f "$f" ]] || return
  if strings "$f" 2>/dev/null | grep -q 'AVFFrameReceiver'; then
    echo "ERROR: $name still contains AVFFrameReceiver (rebuild FFmpeg/mpv with avdevice disabled)" >&2
    fail=1
    return
  fi
  if strings "$f" 2>/dev/null | grep -q 'libavdevice license'; then
    echo "ERROR: $name still embeds libavdevice" >&2
    fail=1
    return
  fi
  echo "ok $name: no libavdevice / AVFFrameReceiver"
}

# libmpv 构建为 -Dcplayer=false；FULLCONFIG「List of enabled features: …」只在
# player/main.c 的 verbose 路径里用到。macOS 链接可能 dead-strip 掉该串，且 BSD
# grep 对超长行（FULLCONFIG）也不稳定。因此用实际编进 libmpv 的符号/字面量检测。
has_str() {
  local f="$1"
  local pat="$2"
  # -a：扫整个文件（Mach-O/PE 都需要）；不支持时回退
  if strings -a "$f" 2>/dev/null | grep -Fq -- "$pat"; then
    return 0
  fi
  strings "$f" 2>/dev/null | grep -Fq -- "$pat"
}

check_android_parity() {
  local f="$1"
  local name="$2"
  [[ -f "$f" ]] || return
  local missing=""
  # uchardet：charset_conv.c
  has_str "$f" "libuchardet detected charset" || missing="$missing uchardet"
  # libarchive：stream_libarchive.c
  has_str "$f" "libarchive" || missing="$missing libarchive"
  # rubberband：af_rubberband.c
  has_str "$f" "librubberband initialization failed" || missing="$missing rubberband"
  # libass：常见符号/串（静态链或动态依赖名）
  if ! has_str "$f" "ass_library_init" && ! has_str "$f" "libass"; then
    missing="$missing libass"
  fi
  # iconv：charset_conv.c
  has_str "$f" "not supported by iconv" || has_str "$f" "Error opening iconv" \
    || missing="$missing iconv"
  # cplugins：scripting.c
  has_str "$f" "mpv_open_cplugin" || has_str "$f" "cplugin" \
    || missing="$missing cplugins"
  if [[ -n "$missing" ]]; then
    echo "ERROR: $name missing portable features:$missing" >&2
    fail=1
    return
  fi
  echo "ok $name: uchardet libarchive rubberband libass iconv cplugins"
}

check_iso() {
  local f="$1"
  local name="$2"
  [[ -f "$f" ]] || return
  local ok_dvd=0 ok_bd=0
  # stream_dvdnav.c 编入后必有 ifo_dvdnav / dvdnav_open（静态链 libdvdnav 时亦有）
  if has_str "$f" "dvdnav_open" || has_str "$f" "ifo_dvdnav"; then
    ok_dvd=1
  fi
  # stream_bluray.c
  if has_str "$f" "bd_open" || has_str "$f" "bdmv/bluray"; then
    ok_bd=1
  fi
  if [[ "$ok_dvd" == 1 && "$ok_bd" == 1 ]]; then
    echo "ok $name: ISO (dvdnav + libbluray)"
    return
  fi
  echo "ERROR: $name lacks DVD/Blu-ray ISO (rebuild with -Ddvdnav=enabled -Dlibbluray=enabled)" >&2
  echo "  markers: dvd=$ok_dvd bluray=$ok_bd" >&2
  fail=1
}

check_libcurl() {
  local f="$1"
  local name="$2"
  [[ -f "$f" ]] || return
  if has_str "$f" "curl_easy_init" || has_str "$f" "libcurl" || has_str "$f" "mpv_curl"; then
    echo "ok $name: libcurl enabled"
  elif command -v otool >/dev/null 2>&1 && otool -L "$f" 2>/dev/null | grep -Eiq 'libcurl'; then
    echo "ok $name: libcurl linked (otool)"
  elif nm -g "$f" 2>/dev/null | grep -Eiq 'curl_easy_init'; then
    echo "ok $name: libcurl symbols (nm)"
  elif command -v dumpbin >/dev/null 2>&1 && dumpbin /DEPENDENTS "$f" 2>/dev/null | grep -Eiq 'libcurl|curl'; then
    echo "ok $name: libcurl linked (dumpbin)"
  else
    echo "ERROR: $name lacks libcurl (rebuild with -Dlibcurl=enabled + ensure-desktop-curl-openssl.sh)" >&2
    fail=1
  fi
}

# Windows：FFmpeg Schannel 负责播流 HTTPS；mpv 也要有 libcurl（HTTP/2+3）。
check_win_https() {
  local f="$1"
  local name="$2"
  [[ -f "$f" ]] || return
  if strings "$f" 2>/dev/null | grep -Eiq 'schannel|https protocol|tls_schannel|HTTPS'; then
    echo "ok $name: HTTPS/schannel markers"
    return
  fi
  echo "WARN: $name HTTPS markers weak (FFmpeg should still have --enable-schannel)" >&2
}

echo "==> verify desktop libmpv (Vulkan + AV3A + network)"
if [[ -z "${KOTV_VERIFY_PLAT:-}" || "${KOTV_VERIFY_PLAT}" == windows* ]]; then
  check_vulkan "$ASSET/windows/mpv-2.dll" "windows/mpv-2.dll"
  check_av3a "$ASSET/windows/mpv-2.dll" "windows/mpv-2.dll"
  check_libcurl "$ASSET/windows/mpv-2.dll" "windows/mpv-2.dll"
  check_iso "$ASSET/windows/mpv-2.dll" "windows/mpv-2.dll"
  check_android_parity "$ASSET/windows/mpv-2.dll" "windows/mpv-2.dll"
  check_win_https "$ASSET/windows/mpv-2.dll" "windows/mpv-2.dll"
  if [[ -f "$ASSET/windows/mpv-2.dll" ]]; then
    if ! ls "$ASSET/windows"/libcurl*.dll >/dev/null 2>&1; then
      echo "ERROR: windows assets missing libcurl*.dll (HTTP/2+3)" >&2
      fail=1
    else
      echo "ok windows: libcurl dll present"
    fi
    if ! ls "$ASSET/windows"/libssl*.dll >/dev/null 2>&1; then
      echo "ERROR: windows assets missing libssl*.dll" >&2
      fail=1
    else
      echo "ok windows: libssl dll present"
    fi
    chmod +x "$ROOT/scripts/verify-windows-mpv-bundle.sh"
    "$ROOT/scripts/verify-windows-mpv-bundle.sh" "$ASSET/windows"
    win_n="$(find "$ASSET/windows" -maxdepth 1 -type f -iname '*.dll' | wc -l | tr -d ' ')"
    echo "ok windows dll count=$win_n"
  fi
fi
if [[ -z "${KOTV_VERIFY_PLAT:-}" || "${KOTV_VERIFY_PLAT}" == linux* ]]; then
  check_vulkan "$ASSET/linux/libmpv.so.2" "linux/libmpv.so.2"
  check_av3a "$ASSET/linux/libmpv.so.2" "linux/libmpv.so.2"
  check_libcurl "$ASSET/linux/libmpv.so.2" "linux/libmpv.so.2"
  check_iso "$ASSET/linux/libmpv.so.2" "linux/libmpv.so.2"
  check_android_parity "$ASSET/linux/libmpv.so.2" "linux/libmpv.so.2"
fi
if [[ -z "${KOTV_VERIFY_PLAT:-}" || "${KOTV_VERIFY_PLAT}" == macos* ]]; then
  if [[ -f "$ASSET/macos/libmpv.dylib" ]]; then
    check_vulkan "$ASSET/macos/libmpv.dylib" "macos/libmpv.dylib"
    check_av3a "$ASSET/macos/libmpv.dylib" "macos/libmpv.dylib"
    check_libcurl "$ASSET/macos/libmpv.dylib" "macos/libmpv.dylib"
    check_iso "$ASSET/macos/libmpv.dylib" "macos/libmpv.dylib"
    check_android_parity "$ASSET/macos/libmpv.dylib" "macos/libmpv.dylib"
    check_no_avdevice "$ASSET/macos/libmpv.dylib" "macos/libmpv.dylib"
    # libmpv 常以 @rpath/libcurl 链接；打包前 assets 必须已有 curl 栈
    if [[ ! -f "$ASSET/macos/libcurl.4.dylib" && ! -f "$ASSET/macos/libcurl.dylib" ]]; then
      echo "ERROR: macos assets missing libcurl*.dylib (stage network stack)" >&2
      fail=1
    else
      echo "ok macos: libcurl dylib staged"
    fi
    if ! ls "$ASSET/macos"/libssl*.dylib >/dev/null 2>&1; then
      echo "ERROR: macos assets missing libssl*.dylib" >&2
      fail=1
    else
      echo "ok macos: libssl dylib staged"
    fi
    if ! ls "$ASSET/macos"/libngtcp2*.dylib >/dev/null 2>&1; then
      echo "ERROR: macos assets missing libngtcp2*.dylib (HTTP/3)" >&2
      fail=1
    else
      echo "ok macos: libngtcp2 dylib staged"
    fi
    # curl 引用的 soname 必须实际存在（避免只有 libngtcp2.16.3.0 却缺 libngtcp2.16）
    if [[ -f "$ASSET/macos/libcurl.4.dylib" ]] || [[ -f "$ASSET/macos/libcurl.dylib" ]]; then
      curl_lib="$ASSET/macos/libcurl.4.dylib"
      [[ -f "$curl_lib" ]] || curl_lib="$ASSET/macos/libcurl.dylib"
      while read -r dep; do
        case "$dep" in
          *libngtcp2*|*libnghttp3*|*libnghttp2*)
            base="$(basename "$dep")"
            if [[ ! -f "$ASSET/macos/$base" ]]; then
              echo "ERROR: macos curl needs $base but assets lack it" >&2
              fail=1
            fi
            ;;
        esac
      done < <(otool -L "$curl_lib" 2>/dev/null | awk 'NR>1 {print $1}')
    fi
  else
    echo "skip macos/libmpv.dylib (not built)"
  fi
fi

[[ "$fail" == 0 ]] || exit 1
echo "==> ok: desktop libmpv network checks passed"
