#!/usr/bin/env bash
# CI：保证 Windows runner 上有可用的 Vulkan SDK（头文件 + Lib），并写出 VULKAN_SDK。
# choco community feed 偶发 504；失败后直下 LunarG 安装器静默安装。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=kotv-win-build-env.sh
source "$ROOT/scripts/kotv-win-build-env.sh"

SDK_VER="${KOTV_VULKAN_SDK_VERSION:-1.4.363.1}"
SDK_ROOT="/c/VulkanSDK/${SDK_VER}"
SDK_ROOT_WIN="C:\\VulkanSDK\\${SDK_VER}"

kotv_vulkan_sdk_ready() {
  local root="$1"
  [[ -f "${root}/Include/vulkan/vulkan.h" ]] || return 1
  # MinGW / meson 需要能链到 vulkan-1（SDK Lib 或 Lib/ARM64）。
  [[ -f "${root}/Lib/vulkan-1.lib" \
    || -f "${root}/Lib/ARM64/vulkan-1.lib" \
    || -f "${root}/Lib/vulkan-1.dll.a" \
    || -f "${root}/Lib/libvulkan-1.a" ]] || return 1
  return 0
}

kotv_pick_vulkan_sdk() {
  local cand
  if [[ -n "${VULKAN_SDK:-}" ]]; then
    cand="$(cygpath -u "${VULKAN_SDK}" 2>/dev/null || echo "${VULKAN_SDK}")"
    cand="${cand%/}"
    if kotv_vulkan_sdk_ready "$cand"; then
      printf '%s' "$cand"
      return 0
    fi
  fi
  if kotv_vulkan_sdk_ready "$SDK_ROOT"; then
    printf '%s' "$SDK_ROOT"
    return 0
  fi
  cand="$(ls -d /c/VulkanSDK/*/ 2>/dev/null | tail -1 || true)"
  cand="${cand%/}"
  if [[ -n "$cand" ]] && kotv_vulkan_sdk_ready "$cand"; then
    printf '%s' "$cand"
    return 0
  fi
  return 1
}

kotv_export_vulkan_sdk() {
  local root="$1" win
  win="$(cygpath -w "$root" 2>/dev/null || echo "$root")"
  export VULKAN_SDK="$win"
  if [[ -n "${GITHUB_ENV:-}" ]]; then
    echo "VULKAN_SDK=${win}" >>"$GITHUB_ENV"
  fi
  echo "ok VULKAN_SDK=${win}"
}

kotv_choco_install_vulkan_sdk() {
  local i
  for i in 1 2 3; do
    echo "==> choco install vulkan-sdk (attempt $i)"
    if choco install vulkan-sdk -y --no-progress; then
      return 0
    fi
    echo "WARN: choco vulkan-sdk attempt $i failed" >&2
    sleep $((i * 5))
  done
  return 1
}

kotv_lunarg_install_vulkan_sdk() {
  local url exe arch
  arch="$(kotv_windows_vulkan_arch)"
  url="${KOTV_VULKAN_SDK_URL:-https://sdk.lunarg.com/sdk/download/${SDK_VER}/windows/vulkansdk-windows-${arch}-${SDK_VER}.exe}"
  exe="${RUNNER_TEMP:-/tmp}/vulkansdk-windows-${arch}-${SDK_VER}.exe"
  echo "==> download Vulkan SDK ${SDK_VER} (${arch}) from LunarG"
  curl -fsSL --connect-timeout 30 --retry 3 --retry-delay 5 --max-time 900 -o "$exe" "$url" \
    || { echo "ERROR: download Vulkan SDK failed: $url" >&2; return 1; }
  echo "==> silent install -> ${SDK_ROOT_WIN}"
  # 与 chocolatey 包 silentArgs 一致。直接调 exe：经 cmd //c 时 MSYS 把内层引号转成 \"，cmd 认不出。
  MSYS_NO_PATHCONV=1 "$exe" install --accept-licenses --confirm-command --accept-messages --root "$SDK_ROOT_WIN" \
    || { echo "ERROR: LunarG Vulkan SDK installer failed" >&2; return 1; }
  kotv_vulkan_sdk_ready "$SDK_ROOT" \
    || { echo "ERROR: Vulkan SDK installed but headers/libs missing under $SDK_ROOT" >&2; ls -la "$SDK_ROOT" >&2 || true; return 1; }
}

main() {
  local root
  if root="$(kotv_pick_vulkan_sdk)"; then
    kotv_export_vulkan_sdk "$root"
    return 0
  fi

  kotv_choco_install_vulkan_sdk || true
  if root="$(kotv_pick_vulkan_sdk)"; then
    kotv_export_vulkan_sdk "$root"
    return 0
  fi

  echo "WARN: choco vulkan-sdk unavailable; falling back to LunarG installer" >&2
  kotv_lunarg_install_vulkan_sdk
  root="$(kotv_pick_vulkan_sdk)" \
    || { echo "ERROR: Vulkan SDK still missing after LunarG install" >&2; exit 1; }
  kotv_export_vulkan_sdk "$root"
}

main "$@"
