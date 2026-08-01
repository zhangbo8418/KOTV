#!/usr/bin/env bash
# 统一发行名：KO影视-{version}-{arch}.{ext}
# 用法: kotv_release_version [pubspec路径]
kotv_release_version() {
  local pubspec="${1:-}"
  if [[ -n "${KOTV_VERSION:-}" ]]; then
    echo "${KOTV_VERSION#v}"
    return
  fi
  if [[ -z "$pubspec" ]]; then
    pubspec="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/flutter/pubspec.yaml"
  fi
  local v
  v="$(sed -nE 's/^version:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' "$pubspec" | head -1)"
  echo "${v:-0.0.0}"
}

# 平台 → 发行 arch 标签（与 Android aarch64/armv7 命名一致）
# 输入: arm64-v8a|armeabi-v7a|android-arm64|android-arm|macos-arm64|macos-x64|windows-x64|windows-arm64|linux-x64|...
kotv_release_arch() {
  case "$1" in
    arm64-v8a|android-arm64|macos-arm64|windows-arm64|linux-arm64|aarch64|arm64)
      echo "aarch64"
      ;;
    armeabi-v7a|android-arm|android-armv7|armv7)
      echo "armv7"
      ;;
    macos-x64|windows-x64|linux-x64|x86_64|amd64)
      echo "x86_64"
      ;;
    *)
      echo "$1"
      ;;
  esac
}
