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

# 从 SDK root 读本脚本写入的宿主 arch 标记（LunarG warm/ARM64 安装后）。
kotv_vulkan_sdk_marked_arch() {
  local root="$1" f
  f="${root}/.kotv_host_arch"
  [[ -f "$f" ]] || return 1
  tr -d '[:space:]' <"$f"
}

# Python：读 MSVC import .lib（ar 归档）首个 COFF 成员的 Machine（0xAA64=ARM64, 0x8664=AMD64）。
kotv_vulkan_lib_coff_machine() {
  local lib="$1" py
  for py in python python3; do
    command -v "$py" >/dev/null 2>&1 || continue
    "$py" - "$lib" <<'PY' 2>/dev/null && return 0
import struct, sys
data = open(sys.argv[1], "rb").read()
if data.startswith(b"!<arch>\n"):
    off = 8
    while off + 60 <= len(data):
        hdr = data[off : off + 60]
        name = hdr[:16].decode("ascii", "replace").rstrip()
        try:
            size = int(hdr[48:58].decode("ascii", "replace").strip())
        except ValueError:
            break
        body = off + 60
        if name not in ("/", "//"):
            print("0x%04X" % struct.unpack_from("<H", data, body)[0])
            sys.exit(0)
        off = body + size + (size & 1)
    sys.exit(1)
if len(data) >= 2:
    print("0x%04X" % struct.unpack_from("<H", data, 0)[0])
    sys.exit(0)
sys.exit(1)
PY
  done
  return 1
}

# 粗判 import lib 是否为本机 arch（避免链上 choco/X64 的 vulkan-1.lib）。
kotv_vulkan_lib_arch_ok() {
  local lib="$1" out mach root
  [[ -f "$lib" ]] || return 1

  # Lib/ARM64 路径本身即交叉/可选 ARM64 组件。
  case "$lib" in */Lib/ARM64/*)
    kotv_windows_is_arm64 && return 0
    return 1
    ;;
  esac

  # LunarG ARM64 安装器写入的标记：原生 SDK 的 Lib/ 可信。
  root="${lib%/Lib/*}"
  [[ "$root" == "$lib" ]] && root="${lib%/*}"
  if kotv_windows_is_arm64; then
    out="$(kotv_vulkan_sdk_marked_arch "$root" 2>/dev/null || true)"
    [[ "$out" == "ARM64" ]] && return 0
  fi

  mach="$(kotv_vulkan_lib_coff_machine "$lib" || true)"
  if [[ -n "$mach" ]]; then
    if kotv_windows_is_arm64; then
      [[ "$mach" == "0xAA64" ]] && return 0
      return 1
    fi
    [[ "$mach" == "0x8664" ]] && return 0
    return 1
  fi

  if command -v llvm-readobj >/dev/null 2>&1; then
    out="$(llvm-readobj --coff-file-header "$lib" 2>/dev/null || true)"
  elif command -v aarch64-w64-mingw32-readobj >/dev/null 2>&1; then
    out="$(aarch64-w64-mingw32-readobj --coff-file-header "$lib" 2>/dev/null || true)"
  elif command -v x86_64-w64-mingw32-readobj >/dev/null 2>&1; then
    out="$(x86_64-w64-mingw32-readobj --coff-file-header "$lib" 2>/dev/null || true)"
  else
    out=""
  fi
  if [[ -n "$out" ]]; then
    if kotv_windows_is_arm64; then
      printf '%s' "$out" | grep -qiE 'Machine:.*(ARM64|AARCH64)|IMAGE_FILE_MACHINE_ARM64' && return 0
      return 1
    fi
    printf '%s' "$out" | grep -qiE 'Machine:.*(AMD64|x64|X86_64)|IMAGE_FILE_MACHINE_AMD64' && return 0
    return 1
  fi

  # 无任何校验手段：arm64 拒 Lib/（防 X64 残留）；x64 默认信。
  if kotv_windows_is_arm64; then
    return 1
  fi
  return 0
}

# 返回本机 arch 对应的 Lib 目录；不对则空。
kotv_vulkan_sdk_libdir() {
  local root="$1" cand
  if kotv_windows_is_arm64; then
    # 优先 Lib/ARM64（X64 SDK 可选组件 / 交叉）；其次原生 ARM64 SDK 的 Lib/（须 arch 校验）。
    for cand in "${root}/Lib/ARM64" "${root}/Lib"; do
      [[ -f "${cand}/vulkan-1.lib" ]] || continue
      kotv_vulkan_lib_arch_ok "${cand}/vulkan-1.lib" || continue
      printf '%s' "$cand"
      return 0
    done
    return 1
  fi
  for cand in "${root}/Lib" "${root}/Lib/X64"; do
    [[ -f "${cand}/vulkan-1.lib" ]] || continue
    printf '%s' "$cand"
    return 0
  done
  [[ -f "${root}/Lib/vulkan-1.dll.a" || -f "${root}/Lib/libvulkan-1.a" ]] \
    && { printf '%s' "${root}/Lib"; return 0; }
  return 1
}

kotv_vulkan_sdk_ready() {
  local root="$1"
  [[ -f "${root}/Include/vulkan/vulkan.h" ]] || return 1
  kotv_vulkan_sdk_libdir "$root" >/dev/null || return 1
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
  local url exe arch channel
  arch="$(kotv_windows_vulkan_arch)"
  channel="$(kotv_windows_vulkan_sdk_channel)"
  # ARM64：sdk.lunarg.com/.../warm/... ；X64：.../windows/...（warm 路径以外 404）。
  url="${KOTV_VULKAN_SDK_URL:-https://sdk.lunarg.com/sdk/download/${SDK_VER}/${channel}/vulkansdk-windows-${arch}-${SDK_VER}.exe}"
  exe="${RUNNER_TEMP:-/tmp}/vulkansdk-windows-${arch}-${SDK_VER}.exe"
  echo "==> download Vulkan SDK ${SDK_VER} (${arch}, channel=${channel}) from LunarG"
  curl -fsSL --connect-timeout 30 --retry 3 --retry-delay 5 --max-time 900 -o "$exe" "$url" \
    || { echo "ERROR: download Vulkan SDK failed: $url" >&2; return 1; }
  # arm64：清掉可能残留的 X64 SDK，避免 Lib/ 仍是 x64。
  if kotv_windows_is_arm64 && [[ -d "$SDK_ROOT" ]]; then
    echo "==> remove stale Vulkan SDK at $SDK_ROOT (may be X64)"
    rm -rf "$SDK_ROOT"
  fi
  echo "==> silent install -> ${SDK_ROOT_WIN}"
  # 与 chocolatey 包 silentArgs 一致。直接调 exe：经 cmd //c 时 MSYS 把内层引号转成 \"，cmd 认不出。
  MSYS_NO_PATHCONV=1 "$exe" install --accept-licenses --confirm-command --accept-messages --root "$SDK_ROOT_WIN" \
    || { echo "ERROR: LunarG Vulkan SDK installer failed" >&2; return 1; }
  # 原生 ARM64 安装器把库放在 Lib/（不一定有 Lib/ARM64）；写标记供 arch 校验信任。
  if kotv_windows_is_arm64; then
    printf 'ARM64\n' >"${SDK_ROOT}/.kotv_host_arch"
  fi
  kotv_vulkan_sdk_ready "$SDK_ROOT" \
    || { echo "ERROR: Vulkan SDK installed but headers/libs missing/wrong-arch under $SDK_ROOT" >&2
         ls -la "$SDK_ROOT/Lib" "$SDK_ROOT/Lib/ARM64" 2>/dev/null || true
         return 1; }
}

main() {
  local root
  if root="$(kotv_pick_vulkan_sdk)"; then
    kotv_export_vulkan_sdk "$root"
    return 0
  fi

  # windows-arm64：choco 社区包常装成 X64 SDK（Lib/ 无 ARM64），跳过直接走 LunarG ARM64。
  if ! kotv_windows_is_arm64; then
    kotv_choco_install_vulkan_sdk || true
    if root="$(kotv_pick_vulkan_sdk)"; then
      kotv_export_vulkan_sdk "$root"
      return 0
    fi
    echo "WARN: choco vulkan-sdk unavailable; falling back to LunarG installer" >&2
  else
    echo "==> windows-arm64: skip choco vulkan-sdk (often X64); use LunarG ARM64" >&2
  fi

  kotv_lunarg_install_vulkan_sdk
  root="$(kotv_pick_vulkan_sdk)" \
    || { echo "ERROR: Vulkan SDK still missing after LunarG install (arm64: need ARM64 vulkan-1.lib)" >&2
         ls -la "${SDK_ROOT}/Lib" "${SDK_ROOT}/Lib/ARM64" 2>/dev/null || true
         exit 1; }
  kotv_export_vulkan_sdk "$root"
}

main "$@"
