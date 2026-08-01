#!/usr/bin/env bash
# 从 kotv-icon-win.png 裁掉透明边距，生成 KOTV.ico 与 Flutter app_icon.ico
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/resources/icons/kotv-icon-win.png"
OUT_ICO="$ROOT/resources/icons/KOTV.ico"
OUT_FLUTTER="$ROOT/flutter/windows/runner/resources/app_icon.ico"

[[ -f "$SRC" ]] || { echo "missing $SRC" >&2; exit 1; }

# CI 可能未装 Pillow：若 ico 已入库则跳过重生成
if ! python3 -c 'import PIL' 2>/dev/null; then
  if [[ -f "$OUT_ICO" && -f "$OUT_FLUTTER" ]]; then
    echo "PIL missing; reuse existing $OUT_ICO / $OUT_FLUTTER"
    exit 0
  fi
  echo "PIL missing; trying pip install pillow..." >&2
  python3 -m pip install --user pillow >/dev/null
fi

export ROOT
python3 <<'PY'
from PIL import Image
import os
import math

root = os.environ["ROOT"]
src = os.path.join(root, "resources/icons/kotv-icon-win.png")
out_ico = os.path.join(root, "resources/icons/KOTV.ico")
out_flutter = os.path.join(root, "flutter/windows/runner/resources/app_icon.ico")

im = Image.open(src).convert("RGBA")
# 低 alpha 也会占据 bbox，先做阈值掩码再裁边，避免“看起来仍有空白”
alpha = im.split()[-1]
mask = alpha.point(lambda a: 255 if a >= 12 else 0)
bbox = mask.getbbox()
if not bbox:
    raise SystemExit("empty image")
cropped = im.crop(bbox)

# ICO 在任务栏通常会视觉偏小，额外放大一点
scale = 1.12
zw = int(round(cropped.width * scale))
zh = int(round(cropped.height * scale))
zoomed = cropped.resize((zw, zh), Image.Resampling.LANCZOS)

size = max(zoomed.size)
square = Image.new("RGBA", (size, size), (0, 0, 0, 0))
ox = (size - zoomed.width) // 2
oy = (size - zoomed.height) // 2
square.paste(zoomed, (ox, oy), zoomed)

# 回写 PNG（与 Windows 资源同源）
trimmed_png = os.path.join(root, "resources/icons/kotv-icon-win.png")
square.resize((1024, 1024), Image.Resampling.LANCZOS).save(trimmed_png)

master = square.resize((1024, 1024), Image.Resampling.LANCZOS)
sizes = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
for path in (out_ico, out_flutter):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    master.save(
        path,
        format="ICO",
        sizes=sizes,
    )
    print("wrote", path)
print("trimmed png", trimmed_png, "from bbox", bbox, "scale", scale)
PY

echo "done: $OUT_ICO + $OUT_FLUTTER"
