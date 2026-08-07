#!/usr/bin/env bash
# 仅构建 Flutter Web → webapp/（开发：放引擎旁即可同端口预览）。正式发行用 package-flutter-web.sh。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLUTTER_BIN="${FLUTTER_BIN:-$(command -v flutter || true)}"
if [[ -z "$FLUTTER_BIN" && -x "$HOME/flutter/bin/flutter" ]]; then
  FLUTTER_BIN="$HOME/flutter/bin/flutter"
fi
if [[ -z "$FLUTTER_BIN" ]]; then
  echo "flutter not found; set FLUTTER_BIN" >&2
  exit 1
fi
OUT="${1:-$ROOT/webapp}"
echo "Building Flutter Web → $OUT"
cd "$ROOT/flutter"
"$FLUTTER_BIN" build web --base-href / --no-wasm-dry-run
rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
cp -R "$ROOT/flutter/build/web" "$OUT"
echo "OK: $OUT"
echo "放到引擎可执行文件旁后访问 http://127.0.0.1:9978/ （遥控见 /remote/）"
