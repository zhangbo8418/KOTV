#!/usr/bin/env bash
# macOS 内置 MPV 与 fvp/mdk 同进程会冲突（mdk 的 libffmpeg + libmpv 内嵌 FFmpeg → demux SIGSEGV）。
# 默认 macOS 全功能（MPV/media_kit + FVP）；仅 MPV 时用 KOTV_MACOS_NO_FVP=1。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLUTTER="$ROOT/flutter"
DEPS="$FLUTTER/.flutter-plugins-dependencies"
REG="$FLUTTER/macos/Flutter/GeneratedPluginRegistrant.swift"

if [[ "${KOTV_MACOS_NO_FVP:-0}" != "1" ]]; then
  echo "==> macOS keep fvp/mdk (KOTV_MACOS_NO_FVP=0)"
  exit 0
fi

echo "==> macOS exclude fvp/mdk (MPV-only; avoids libffmpeg clash)"

if [[ ! -f "$DEPS" ]]; then
  echo "ERROR: missing $DEPS (run flutter pub get first)" >&2
  exit 1
fi

python3 <<PY
import json
from pathlib import Path
path = Path(r"""$DEPS""")
data = json.loads(path.read_text())
mac = data.get("plugins", {}).get("macos", [])
data["plugins"]["macos"] = [p for p in mac if p.get("name") != "fvp"]
path.write_text(json.dumps(data, separators=(",", ":")))
print("  - removed fvp from .flutter-plugins-dependencies[macos]")
PY

if [[ -f "$FLUTTER/.flutter-plugins" ]]; then
  grep -v '^fvp=' "$FLUTTER/.flutter-plugins" > "$FLUTTER/.flutter-plugins.tmp" || true
  mv "$FLUTTER/.flutter-plugins.tmp" "$FLUTTER/.flutter-plugins"
  echo "  - removed fvp from .flutter-plugins"
fi

SYMLINK="$FLUTTER/macos/Flutter/ephemeral/.symlinks/plugins/fvp"
if [[ -d "$SYMLINK" || -L "$SYMLINK" ]]; then
  rm -rf "$SYMLINK"
  echo "  - removed ephemeral fvp plugin symlink"
fi

if [[ -f "$REG" ]]; then
  python3 <<PY
from pathlib import Path
import re
path = Path(r"""$REG""")
text = path.read_text()
text = re.sub(r'^import fvp\n', '', text, flags=re.M)
text = re.sub(r'^\s*FvpPlugin\.register\(.*\)\n', '', text, flags=re.M)
path.write_text(text)
print("  - patched GeneratedPluginRegistrant.swift")
PY
fi
