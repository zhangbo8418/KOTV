#!/usr/bin/env bash
# 按 series 文件的行顺序把补丁打到 git 源码树上（# 之后为注释）。
# 先把源码树还原成检出时的样子，任何一个补丁打不上都直接失败。
# 用法: kotv-apply-patch-series.sh <series-file> <patch-dir> <git-src-dir>
set -euo pipefail
SERIES="${1:-}"
PATCH_DIR="${2:-}"
SRC="${3:-}"
[[ -f "$SERIES" && -d "$PATCH_DIR" && -d "$SRC/.git" ]] \
  || { echo "usage: $0 <series-file> <patch-dir> <git-src-dir>" >&2; exit 1; }

git -C "$SRC" checkout -qf HEAD -- .
git -C "$SRC" clean -fdq

log="$(mktemp)"
trap 'rm -f "$log"' EXIT
while IFS= read -r line || [[ -n "$line" ]]; do
  f="${line%%#*}"
  f="$(echo "$f" | tr -d '[:space:]')"
  [[ -z "$f" ]] && continue
  [[ -f "$PATCH_DIR/$f" ]] || { echo "ERROR: missing patch $PATCH_DIR/$f" >&2; exit 1; }
  if ! patch -p1 --forward --batch -d "$SRC" <"$PATCH_DIR/$f" >"$log" 2>&1; then
    cat "$log" >&2
    echo "ERROR: patch $f does not apply to $SRC" >&2
    exit 1
  fi
  echo "ok patch $f"
done <"$SERIES"
find "$SRC" \( -name '*.orig' -o -name '*.rej' \) -delete
