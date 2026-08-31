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

check_no_vulkan() {
  local f="$1"
  local name="$2"
  [[ -f "$f" ]] || { echo "skip $name (not built)"; return; }
  if grep -aqE 'vulkan|pl_vulkan|-Dvulkan=enabled' "$f" 2>/dev/null; then
    echo "ERROR: $name still contains vulkan (Win7 build must use KOTV_MPV_WIN7=1)" >&2
    fail=1
  else
    echo "ok $name: vulkan disabled (Win7 D3D11-only)"
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

echo "==> verify desktop libmpv (Vulkan${KOTV_EXPECT_MPV_AV3A:+ + AV3A})"
if [[ -z "${KOTV_VERIFY_PLAT:-}" || "${KOTV_VERIFY_PLAT}" == windows* ]]; then
  if [[ "${KOTV_MPV_WIN7:-${KOTV_WIN7:-0}}" == "1" ]]; then
    check_no_vulkan "$ASSET/windows/mpv-2.dll" "windows/mpv-2.dll"
  else
    check_vulkan "$ASSET/windows/mpv-2.dll" "windows/mpv-2.dll"
  fi
  check_av3a "$ASSET/windows/mpv-2.dll" "windows/mpv-2.dll"
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
fi
if [[ -z "${KOTV_VERIFY_PLAT:-}" || "${KOTV_VERIFY_PLAT}" == macos* ]]; then
  if [[ -f "$ASSET/macos/libmpv.dylib" ]]; then
    check_vulkan "$ASSET/macos/libmpv.dylib" "macos/libmpv.dylib"
    check_av3a "$ASSET/macos/libmpv.dylib" "macos/libmpv.dylib"
  else
    echo "skip macos/libmpv.dylib (not built)"
  fi
fi

[[ "$fail" == 0 ]] || exit 1
echo "==> ok: desktop libmpv Vulkan checks passed"
