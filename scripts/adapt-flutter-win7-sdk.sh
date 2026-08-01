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
perl -i -pe 's/flutter_lints:\s*\^4\.0\.0/flutter_lints: ^3.0.0/' "$APP"

# 钉死对 Dart 3.4+ 的直接依赖
perl -i -pe 's/path_provider:\s*\^2\.1\.5/path_provider: 2.1.4/' "$APP"
perl -i -pe 's/shared_preferences:\s*\^2\.3\.3/shared_preferences: 2.3.0/' "$APP"
# media_kit 1.2.0+ / media_kit_video 1.3.0+ 依赖 web（Dart >=3.4）。
# Win7 = Flutter 3.19 / Dart 3.3，钉到目前能解析的最新一档：1.1.11 + 1.2.5。
perl -i -pe 's/media_kit:\s*("[^"]+"|[^\n]+)/media_kit: 1.1.11/' "$APP"
perl -i -pe 's/media_kit_video:\s*("[^"]+"|[^\n]+)/media_kit_video: 1.2.5/' "$APP"
perl -i -pe 's/media_kit_libs_video:\s*("[^"]+"|[^\n]+)/media_kit_libs_video: 1.0.7/' "$APP"

# kotv_vlc：允许 3.19
perl -i -pe 's/sdk:\s*\^3\.5\.4/sdk: ">=3.3.0 <3.4.0"/' "$VLC"
perl -i -pe 's/flutter:\s*"?>=3\.24\.0"?/flutter: ">=3.19.0"/' "$VLC"

# Flutter 3.44+ 用 DialogThemeData；3.19 ThemeData 仍要 DialogTheme
THEME="$ROOT/flutter/lib/theme/kotv_theme.dart"
if [[ -f "$THEME" ]]; then
  perl -i -pe 's/DialogThemeData\(/DialogTheme(/g' "$THEME"
fi

# 压住传递依赖（path_provider / shared_preferences 平台实现常要求 Dart 3.4+）
if ! grep -q '^dependency_overrides:' "$APP"; then
  cat >> "$APP" <<'EOF'

# Win7 / Flutter 3.19 临时覆盖（由 adapt-flutter-win7-sdk.sh 注入）
dependency_overrides:
  path_provider: 2.1.4
  path_provider_android: 2.2.4
  path_provider_foundation: 2.4.0
  path_provider_linux: 2.2.1
  path_provider_windows: 2.3.0
  shared_preferences: 2.3.0
  shared_preferences_android: 2.2.2
  shared_preferences_foundation: 2.5.2
  shared_preferences_linux: 2.4.1
  shared_preferences_windows: 2.4.1
  media_kit: 1.1.11
  media_kit_video: 1.2.5
  media_kit_libs_video: 1.0.7
EOF
fi

echo "adapted pubspec for Flutter 3.19 / Dart 3.3:"
grep -nE 'sdk:|path_provider|shared_preferences|media_kit|dependency_overrides|flutter_lints' "$APP" | head -60
