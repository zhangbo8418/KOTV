#!/usr/bin/env bash
# 对当前 Flutter SDK 应用仓库内补丁（仅 3.24.x 主线；Win7 3.19 线请跳过）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATCH="$ROOT/.github/patches/flutter_3.24.4_dropdown_menu_enableFilter.diff"

if ! command -v flutter >/dev/null 2>&1; then
  echo "flutter not in PATH" >&2
  exit 1
fi

ver="$(flutter --version 2>/dev/null | head -1 || true)"
if ! echo "$ver" | grep -qE '3\.24\.'; then
  echo "skip SDK patch (not Flutter 3.24.x): $ver"
  exit 0
fi

if [[ ! -f "$PATCH" ]]; then
  echo "missing patch: $PATCH" >&2
  exit 1
fi

sdk_root="$(dirname "$(dirname "$(command -v flutter)")")"
cp -f "$PATCH" "$sdk_root/"
(
  cd "$sdk_root"
  git apply --ignore-space-change --ignore-whitespace flutter_3.24.4_dropdown_menu_enableFilter.diff
)
echo "patched Flutter SDK at $sdk_root"
