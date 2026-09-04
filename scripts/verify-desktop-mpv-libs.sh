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

check_libcurl() {
  local f="$1"
  local name="$2"
  [[ -f "$f" ]] || return
  if strings "$f" 2>/dev/null | grep -Eiq 'List of enabled features:.*libcurl|libcurl=enabled|curl_easy_init|mpv_curl'; then
    echo "ok $name: libcurl enabled"
  else
    echo "ERROR: $name lacks libcurl (rebuild with -Dlibcurl=enabled + ensure-desktop-curl-openssl.sh)" >&2
    fail=1
  fi
}

# Windows：不强制 mpv libcurl；FFmpeg Schannel 负责 HTTPS。
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
  check_win_https "$ASSET/windows/mpv-2.dll" "windows/mpv-2.dll"
  if [[ -f "$ASSET/windows/mpv-2.dll" ]]; then
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
fi
if [[ -z "${KOTV_VERIFY_PLAT:-}" || "${KOTV_VERIFY_PLAT}" == macos* ]]; then
  if [[ -f "$ASSET/macos/libmpv.dylib" ]]; then
    check_vulkan "$ASSET/macos/libmpv.dylib" "macos/libmpv.dylib"
    check_av3a "$ASSET/macos/libmpv.dylib" "macos/libmpv.dylib"
    check_libcurl "$ASSET/macos/libmpv.dylib" "macos/libmpv.dylib"
    check_no_avdevice "$ASSET/macos/libmpv.dylib" "macos/libmpv.dylib"
  else
    echo "skip macos/libmpv.dylib (not built)"
  fi
fi

[[ "$fail" == 0 ]] || exit 1
echo "==> ok: desktop libmpv network checks passed"
