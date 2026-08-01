#!/usr/bin/env bash
# 打包 Flutter Android APK：arm64 + armeabi-v7a Go 引擎 + Spider bridge + 迅雷 AAR
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="${HOME}/flutter/bin:${PATH}"
export PUB_HOSTED_URL="${PUB_HOSTED_URL:-https://pub.flutter-io.cn}"
export FLUTTER_STORAGE_BASE_URL="${FLUTTER_STORAGE_BASE_URL:-https://storage.flutter-io.cn}"

echo "==> build Go engine (android arm64 + armeabi-v7a)"
# QuickJS CGO 头文件（未进 git）
(cd "$ROOT/internal/spider" && go run gen_qjsinc.go)
"$ROOT/scripts/build-engine-flutter.sh" android

for abi in arm64-v8a armeabi-v7a; do
  SO="$ROOT/flutter/android/app/src/main/jniLibs/$abi/libkotv_engine.so"
  [[ -f "$SO" ]] || { echo "missing $SO" >&2; exit 1; }
  ENG_SZ="$(wc -c < "$SO" | tr -d ' ')"
  ENG_SHA="$(shasum -a 256 "$SO" | awk '{print $1}')"
  echo "  ok: $abi -> $SO ($ENG_SZ bytes, sha256=$ENG_SHA)"
  file "$SO" || true
done

AAR="$ROOT/flutter/android/app/libs/thunder-release.aar"
if [[ ! -f "$AAR" ]]; then
  echo "==> thunder-release.aar missing; copy from TV if available"
  if [[ -f "$ROOT/../TV/app/libs/thunder-release.aar" ]]; then
    cp -f "$ROOT/../TV/app/libs/thunder-release.aar" "$AAR"
  elif [[ -f "$HOME/Documents/GitHub/TV/app/libs/thunder-release.aar" ]]; then
    cp -f "$HOME/Documents/GitHub/TV/app/libs/thunder-release.aar" "$AAR"
  else
    echo "missing $AAR (required for Android 迅雷/电驴)" >&2
    exit 1
  fi
fi

if [[ ! -f "$ROOT/bridge/spider-bridge.jar" ]] || [[ ! -s "$ROOT/bridge/spider-bridge.jar" ]]; then
  echo "==> build spider-bridge.jar"
  "$ROOT/bridge/build.sh"
fi

echo "==> flutter build apk --release (arm64 + armv7)"
cd "$ROOT/flutter"
flutter pub get
flutter build apk --release --target-platform=android-arm,android-arm64

APK_SRC="$ROOT/flutter/build/app/outputs/flutter-apk/app-release.apk"
[[ -f "$APK_SRC" ]] || { echo "missing $APK_SRC" >&2; exit 1; }

mkdir -p "$ROOT/dist"
OUT_APK="$ROOT/dist/KO影视-Flutter-android.apk"
cp -f "$APK_SRC" "$OUT_APK"
# 兼容旧文件名
cp -f "$APK_SRC" "$ROOT/dist/KO影视-Flutter-android-arm64.apk"
echo "==> done: $OUT_APK"
ls -lh "$OUT_APK"
