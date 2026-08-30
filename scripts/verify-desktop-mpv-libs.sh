#!/usr/bin/env bash
# 校验桌面 libmpv 预编译包含 Vulkan（libplacebo vulkan 特性）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSET="$ROOT/flutter/assets/mpv-libs"
fail=0

check_vulkan() {
  local f="$1"
  local name="$2"
  [[ -f "$f" ]] || { echo "ERROR: missing $name ($f)" >&2; fail=1; return; }
  if grep -aqE 'vulkan|pl_vulkan|-Dvulkan=enabled' "$f" 2>/dev/null; then
    echo "ok $name: vulkan enabled"
  else
    echo "ERROR: $name lacks vulkan feature (re-fetch or KOTV_BUILD_MPV_FROM_SOURCE=1)" >&2
    fail=1
  fi
}

check_av3a() {
  local f="$1"
  local name="$2"
  [[ -f "$f" ]] || return
  if grep -aqE 'libarcdav3a|AV3A Audio Vivid|--enable-libarcdav3a' "$f" 2>/dev/null; then
    echo "ok $name: AV3A (libarcdav3a)"
  elif [[ "${KOTV_EXPECT_MPV_AV3A:-}" == "1" ]]; then
    echo "ERROR: $name lacks AV3A (set KOTV_BUILD_MPV_AV3A=1 && build-desktop-mpv-from-source.sh)" >&2
    fail=1
  else
    echo "warn $name: no AV3A (prebuilt shinchiro/Ubuntu); use KOTV_BUILD_MPV_AV3A=1 for source build"
  fi
}

echo "==> verify desktop libmpv (Vulkan${KOTV_EXPECT_MPV_AV3A:+ + AV3A})"
check_vulkan "$ASSET/windows/mpv-2.dll" "windows/mpv-2.dll"
check_av3a "$ASSET/windows/mpv-2.dll" "windows/mpv-2.dll"
check_vulkan "$ASSET/linux/libmpv.so.2" "linux/libmpv.so.2"
check_av3a "$ASSET/linux/libmpv.so.2" "linux/libmpv.so.2"
if [[ -f "$ASSET/macos/libmpv.dylib" ]]; then
  check_vulkan "$ASSET/macos/libmpv.dylib" "macos/libmpv.dylib"
  check_av3a "$ASSET/macos/libmpv.dylib" "macos/libmpv.dylib"
else
  echo "skip macos/libmpv.dylib (CI bottle / local fetch)"
fi

[[ "$fail" == 0 ]] || exit 1
echo "==> ok: desktop libmpv Vulkan checks passed"
