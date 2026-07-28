#!/usr/bin/env bash
# 一键：编译 Go 引擎 + flutter run（默认 macos）
# 引擎由 Flutter EngineLauncher 托管，随窗口关闭退出（不再 nohup 常驻）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${1:-macos}"
export PATH="${HOME}/flutter/bin:${PATH}"

"$ROOT/scripts/build-engine-flutter.sh"
# 清掉历史 nohup 残留
pkill -f '/tmp/kotv-engine' 2>/dev/null || true
pkill -f 'Contents/Resources/engine/kotv-engine' 2>/dev/null || true

export KOTV_RUNTIME="${KOTV_RUNTIME:-$ROOT/runtime}"

cd "$ROOT/flutter"
flutter pub get
exec env KOTV_RUNTIME="$KOTV_RUNTIME" flutter run -d "$DEVICE"
