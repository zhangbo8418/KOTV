#!/usr/bin/env bash
# 一键：准备运行时 + 编译到 /tmp/KOTV（开发自测用）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/prepare-runtime.sh" "${1:-}"
(cd "$ROOT/internal/spider" && go run gen_qjsinc.go)
(cd "$ROOT" && CGO_ENABLED=1 go build -o /tmp/KOTV .)
echo "OK: /tmp/KOTV"
echo "runtime status:"
KOTV_RUNTIME="$ROOT/runtime" /tmp/KOTV -version 2>/dev/null || true
# 打印运行时探测（不启动 GUI）：用小工具或 settings 状态
python3 - <<PY
import os, pathlib
root=pathlib.Path("$ROOT")/"runtime"
plats=list(root.glob("*"))
print("platforms:", [p.name for p in plats if p.is_dir()])
for p in plats:
  if not p.is_dir():
    continue
  print(f"== {p.name} ==")
  for name in ["jre","python","chromium","ffmpeg","vlc","mpv","bridge"]:
    d=p/name
    print(f"  {name}: {'OK' if d.exists() else 'MISSING'}")
PY
