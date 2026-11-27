#!/usr/bin/env bash
# 只编 Flutter Web 静态资源到目标目录（不含引擎 / runtime）。
# 群晖 SPK 与 Web zip 共用，避免两处复制 build web 步骤。
# 用法: ./scripts/build-flutter-webapp.sh [dest-dir]
# 默认 dest: flutter/build/web（Flutter 默认产出）；若指定 dest 则再拷一份。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:-}"

FLUTTER_BIN="${FLUTTER_BIN:-$(command -v flutter || true)}"
if [[ -z "$FLUTTER_BIN" && -x "$HOME/flutter/bin/flutter" ]]; then
  FLUTTER_BIN="$HOME/flutter/bin/flutter"
fi
if [[ -z "$FLUTTER_BIN" ]]; then
  echo "flutter not found; set FLUTTER_BIN" >&2
  exit 1
fi

chmod +x "$ROOT/scripts/"*.sh 2>/dev/null || true
echo "==> Flutter Web (base-href /)"
KOTV_FLUTTER_TARGET=web "$ROOT/scripts/flutter-pub-get.sh"
# shellcheck source=kotv-flutter-asset-engines.sh
source "$ROOT/scripts/kotv-flutter-asset-engines.sh"
kotv_flutter_asset_engines_hide
trap kotv_flutter_asset_engines_restore EXIT
cd "$ROOT/flutter"
"$FLUTTER_BIN" config --enable-web
"$FLUTTER_BIN" build web --base-href / --no-wasm-dry-run
kotv_flutter_asset_engines_restore
kotv_flutter_asset_engines_reject "$ROOT/flutter/build/web"
kotv_flutter_strip_placeholder_assets "$ROOT/flutter/build/web/assets" 1

if [[ -n "$DEST" ]]; then
  mkdir -p "$DEST"
  rm -rf "${DEST:?}/"*
  cp -a "$ROOT/flutter/build/web/." "$DEST/"
  echo "webapp → $DEST"
fi
echo "webapp ready: $ROOT/flutter/build/web"
