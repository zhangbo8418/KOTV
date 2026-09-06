#!/usr/bin/env bash
# 统一 flutter pub get：Win7 / Dart 3.3 线自动先跑 adapt，避免 video_player_android 2.11 要 SDK ^3.10。
# 主线：fvp 跟 pub.dev 最新（与 runtime Chromium 跟仓库最新同一策略）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

_kotv_python() {
  if command -v python3 >/dev/null 2>&1; then
    python3 "$@"
  elif command -v python >/dev/null 2>&1; then
    python "$@"
  elif command -v py >/dev/null 2>&1; then
    py -3 "$@"
  else
    return 1
  fi
}

win7=0
if [[ "${KOTV_WIN7:-}" == "1" ]] || flutter --version 2>&1 | grep -qE 'Dart 3\.3\.|Flutter 3\.19'; then
  win7=1
  echo "==> Win7 / Dart 3.3: adapt pubspec before pub get"
  "$ROOT/scripts/adapt-flutter-win7-sdk.sh"
else
  fvp_ver=""
  fvp_ver="$(_kotv_python - <<'PY' || true
import json, urllib.request
url = "https://pub.dev/api/packages/fvp"
req = urllib.request.Request(
    url,
    headers={"User-Agent": "KOTV-flutter-pub-get", "Accept": "application/vnd.pub.v2+json"},
)
with urllib.request.urlopen(req, timeout=30) as resp:
    data = json.load(resp)
print(data["latest"]["version"])
PY
)"
  if [[ -n "$fvp_ver" ]]; then
    echo "==> fvp latest from pub.dev: $fvp_ver"
    perl -i -pe "s/^  fvp:\\s*.*/  fvp: ${fvp_ver}/" "$ROOT/flutter/pubspec.yaml"
  else
    echo "WARN: could not resolve latest fvp; using pubspec as-is (fvp: any)" >&2
  fi
fi

cd "$ROOT/flutter"
flutter pub get "$@"
if [[ "$win7" != "1" ]]; then
  # 避免 committed pubspec.lock 把 any 钉在旧版；已写成精确版本时这步是 no-op。
  flutter pub upgrade fvp
fi
# media_kit _setPropertyFlag 1 字节 Bool 传 MPV_FORMAT_FLAG(int)：Windows 上 play() 变 pause。
# 两条线（主线 / Win7）media_kit 都是 1.2.6，同一补丁；失败即中止，禁止带 bug 出包。
chmod +x "$ROOT/scripts/patch-media-kit.sh"
"$ROOT/scripts/patch-media-kit.sh"
