#!/usr/bin/env bash
# 统一 flutter pub get：Win7 / Dart 3.3 线自动先跑 adapt，避免 video_player_android 2.11 要 SDK ^3.10。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ "${KOTV_WIN7:-}" == "1" ]] || flutter --version 2>&1 | grep -qE 'Dart 3\.3\.|Flutter 3\.19'; then
  echo "==> Win7 / Dart 3.3: adapt pubspec before pub get"
  "$ROOT/scripts/adapt-flutter-win7-sdk.sh"
fi

cd "$ROOT/flutter"
exec flutter pub get "$@"
