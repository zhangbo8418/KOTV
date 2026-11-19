#!/usr/bin/env bash
# 在已检出的 FFmpeg 源码树内应用 mpv-build series.apple（+ common 中 DV 相关）。
# 用法: kotv-apply-ffmpeg-apple-patches.sh <ffmpeg-src-dir>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-}"
[[ -n "$SRC" && -d "$SRC" ]] || { echo "usage: $0 <ffmpeg-src>" >&2; exit 1; }
POOL="$ROOT/scripts/patches/ffmpeg/pool"
SERIES_APPLE="$ROOT/scripts/patches/ffmpeg/series.apple"
[[ -d "$POOL" && -f "$SERIES_APPLE" ]] || { echo "ERROR: missing ffmpeg apple patches" >&2; exit 1; }

apply_one() {
  local patch="$1" label="$2"
  if [[ ! -f "$patch" ]]; then
    echo "WARN: missing $label" >&2
    return 0
  fi
  if patch -p1 --forward --batch -d "$SRC" <"$patch" >/dev/null 2>&1; then
    echo "ok ffmpeg $label"
  elif patch -p1 -R --dry-run --batch -d "$SRC" <"$patch" >/dev/null 2>&1; then
    echo "ok ffmpeg $label already applied"
  else
    echo "WARN: ffmpeg $label did not apply (tree may differ from mpv-build pin); continuing" >&2
  fi
}

# common DV helpers first when present
for f in 0010-hevc-downlevel-duplicate-dovi-rpu-log.patch \
         0021-dolby-vision-convert-profile7-rpu-to-p81.patch; do
  [[ -f "$POOL/$f" ]] && apply_one "$POOL/$f" "$f"
done

while IFS= read -r line || [[ -n "$line" ]]; do
  [[ "$line" =~ ^# ]] && continue
  f="$(echo "$line" | tr -d '[:space:]')"
  [[ -z "$f" ]] && continue
  apply_one "$POOL/$f" "$f"
done < "$SERIES_APPLE"
