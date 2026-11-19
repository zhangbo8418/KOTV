#!/usr/bin/env bash
# 在已检出的 FFmpeg 源码树内应用 Apple / DV 相关补丁。
# FongMi tip 可能已含部分 videotoolbox 调用，但缺 dovi_convert 实现；补丁失败时
# 用 helpers/ 兜底，避免 undeclared ff_dovi_convert_p7_rpu_to_p81。
# 用法: kotv-apply-ffmpeg-apple-patches.sh <ffmpeg-src-dir>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-}"
[[ -n "$SRC" && -d "$SRC" ]] || { echo "usage: $0 <ffmpeg-src>" >&2; exit 1; }
POOL="$ROOT/scripts/patches/ffmpeg/pool"
HELPERS="$ROOT/scripts/patches/ffmpeg/helpers"
SERIES_APPLE="$ROOT/scripts/patches/ffmpeg/series.apple"
[[ -d "$POOL" && -f "$SERIES_APPLE" ]] || { echo "ERROR: missing ffmpeg apple patches" >&2; exit 1; }

apply_one() {
  local patch="$1" label="$2"
  if [[ ! -f "$patch" ]]; then
    echo "WARN: missing $label" >&2
    return 1
  fi
  if patch -p1 --forward --batch -d "$SRC" <"$patch" >/dev/null 2>&1; then
    echo "ok ffmpeg $label"
    return 0
  fi
  if patch -p1 -R --dry-run --batch -d "$SRC" <"$patch" >/dev/null 2>&1; then
    echo "ok ffmpeg $label already applied"
    return 0
  fi
  echo "WARN: ffmpeg $label did not apply (tree may differ); continuing" >&2
  return 1
}

# common DV helpers first when present
for f in 0010-hevc-downlevel-duplicate-dovi-rpu-log.patch \
         0021-dolby-vision-convert-profile7-rpu-to-p81.patch; do
  [[ -f "$POOL/$f" ]] && apply_one "$POOL/$f" "$f" || true
done

while IFS= read -r line || [[ -n "$line" ]]; do
  [[ "$line" =~ ^# ]] && continue
  f="$(echo "$line" | tr -d '[:space:]')"
  [[ -z "$f" ]] && continue
  apply_one "$POOL/$f" "$f" || true
done < "$SERIES_APPLE"

# tip 已含 ff_dovi_convert 调用、但 0021 未贴上时：从 helpers 补文件 + Makefile。
ensure_dovi_convert() {
  local vt="$SRC/libavcodec/videotoolbox.c"
  local c="$SRC/libavcodec/dovi_convert.c"
  local h="$SRC/libavcodec/dovi_convert.h"
  local mk="$SRC/libavcodec/Makefile"
  if [[ ! -f "$vt" ]] || ! grep -q 'ff_dovi_convert_p7_rpu_to_p81' "$vt"; then
    return 0
  fi
  if [[ -f "$c" && -f "$h" ]]; then
    echo "ok ffmpeg dovi_convert sources present"
  else
    [[ -f "$HELPERS/dovi_convert.c" && -f "$HELPERS/dovi_convert.h" ]] \
      || { echo "ERROR: need $HELPERS/dovi_convert.{c,h}" >&2; exit 1; }
    cp -f "$HELPERS/dovi_convert.c" "$c"
    cp -f "$HELPERS/dovi_convert.h" "$h"
    echo "ok ffmpeg installed dovi_convert.{c,h} from helpers"
  fi
  python3 - "$SRC" <<'PY'
import pathlib, sys
src = pathlib.Path(sys.argv[1])
mk = src / "libavcodec" / "Makefile"
vt = src / "libavcodec" / "videotoolbox.c"
if mk.is_file() and "dovi_convert.o" not in mk.read_text():
    text = mk.read_text()
    needle = "OBJS-$(CONFIG_DOVI_RPUENC)"
    i = text.find(needle)
    if i < 0:
        print("ERROR: cannot wire dovi_convert.o into Makefile", file=sys.stderr)
        sys.exit(1)
    end = text.find("\n", i)
    insert = (
        "\nOBJS-$(CONFIG_MEDIACODEC)              += dovi_convert.o"
        "\nOBJS-$(CONFIG_VIDEOTOOLBOX)            += dovi_convert.o"
    )
    mk.write_text(text[:end] + insert + text[end:])
    print("ok ffmpeg Makefile OBJS dovi_convert")
if mk.is_file() and "dovi_convert.h" not in mk.read_text():
    text = mk.read_text()
    needle = "SKIPHEADERS-$(CONFIG_ZLIB)"
    i = text.find(needle)
    if i >= 0:
        end = text.find("\n", i)
        insert = (
            "\nSKIPHEADERS-$(CONFIG_MEDIACODEC)       += dovi_convert.h"
            "\nSKIPHEADERS-$(CONFIG_VIDEOTOOLBOX)     += dovi_convert.h"
        )
        mk.write_text(text[:end] + insert + text[end:])
        print("ok ffmpeg Makefile SKIPHEADERS dovi_convert")
if vt.is_file() and "dovi_convert.h" not in vt.read_text():
    text = vt.read_text()
    needle = '#include "videotoolbox.h"'
    i = text.find(needle)
    if i >= 0:
        end = text.find("\n", i)
        vt.write_text(text[:end] + '\n#include "dovi_convert.h"' + text[end:])
        print("ok ffmpeg videotoolbox includes dovi_convert.h")
    else:
        print('WARN: add #include "dovi_convert.h" to videotoolbox.c if build fails', file=sys.stderr)
PY
}

ensure_dovi_convert

if grep -q 'ff_dovi_convert_p7_rpu_to_p81' "$SRC/libavcodec/videotoolbox.c" 2>/dev/null \
  && [[ ! -f "$SRC/libavcodec/dovi_convert.c" ]]; then
  echo "ERROR: videotoolbox calls ff_dovi_convert_p7_rpu_to_p81 but dovi_convert.c missing" >&2
  exit 1
fi
