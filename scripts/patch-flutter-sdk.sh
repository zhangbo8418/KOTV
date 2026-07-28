#!/usr/bin/env bash
# 对当前 Flutter SDK 应用仓库内补丁（Win7 实验线使用 3.24.5）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATCH="$ROOT/.github/patches/flutter_3.24.4_dropdown_menu_enableFilter.diff"

if ! command -v flutter >/dev/null 2>&1; then
  echo "flutter not in PATH" >&2
  exit 1
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
