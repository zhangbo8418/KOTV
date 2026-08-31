#!/usr/bin/env bash
# 拉取/构建 iOS libmpv → flutter/assets/mpv-libs/ios/libmpv.dylib
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSET="$ROOT/flutter/assets/mpv-libs/ios"
mkdir -p "$ASSET"

marker_ok() {
  local f="$1" min="${2:-500000}"
  [[ -f "$f" && "$(wc -c <"$f" | tr -d ' ')" -ge "$min" ]]
}

OUT="$ASSET/libmpv.dylib"
if marker_ok "$OUT" && grep -aqE 'libarcdav3a|AV3A Audio Vivid' "$OUT" 2>/dev/null \
  && [[ "$(cat "$ASSET/.kind" 2>/dev/null || true)" == "av3a-ios-v1" ]]; then
  echo "ok ios/libmpv.dylib (cached AV3A)"
  exit 0
fi

echo "==> ios libmpv: source build with AV3A (FongMi FFmpeg + meson)"
chmod +x "$ROOT/scripts/build-ios-mpv-from-source.sh"
"$ROOT/scripts/build-ios-mpv-from-source.sh"
echo av3a-ios-v1 >"$ASSET/.kind"
du -sh "$ASSET" 2>/dev/null || true
echo "==> done"
