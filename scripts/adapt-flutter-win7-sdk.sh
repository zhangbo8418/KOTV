#!/usr/bin/env bash
# 将 Flutter 工程约束临时放宽到 3.19 / Dart 3.3，供 Win7 实验线 CI 使用。
# 不提交改动到 git；仅影响当前工作区。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/flutter/pubspec.yaml"
VLC="$ROOT/flutter/packages/kotv_vlc/pubspec.yaml"

[[ -f "$APP" ]] || { echo "missing $APP" >&2; exit 1; }
[[ -f "$VLC" ]] || { echo "missing $VLC" >&2; exit 1; }

# 主工程：Dart 3.3（Flutter 3.19）
perl -i -pe 's/sdk:\s*\^3\.5\.4/sdk: ">=3.3.0 <3.4.0"/' "$APP"
# 过新的 lint 在 3.19 上常不可用
perl -i -pe 's/flutter_lints:\s*\^4\.0\.0/flutter_lints: ^3.0.0/' "$APP"

# kotv_vlc：允许 3.19
perl -i -pe 's/sdk:\s*\^3\.5\.4/sdk: ">=3.3.0 <3.4.0"/' "$VLC"
perl -i -pe 's/flutter:\s*"?>=3\.24\.0"?/flutter: ">=3.19.0"/' "$VLC"

echo "adapted pubspec for Flutter 3.19 / Dart 3.3:"
grep -E 'sdk:|flutter:' "$APP" "$VLC" | head -20
