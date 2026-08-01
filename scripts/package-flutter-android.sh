#!/usr/bin/env bash
# 打包 Flutter Android：按 ABI 拆包
#   dist/KO影视-{version}-aarch64.apk
#   dist/KO影视-{version}-armv7.apk
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=kotv-release-name.sh
source "$ROOT/scripts/kotv-release-name.sh"
export PATH="${HOME}/flutter/bin:${PATH}"
export PUB_HOSTED_URL="${PUB_HOSTED_URL:-https://pub.flutter-io.cn}"
export FLUTTER_STORAGE_BASE_URL="${FLUTTER_STORAGE_BASE_URL:-https://storage.flutter-io.cn}"

VERSION="$(kotv_release_version "$ROOT/flutter/pubspec.yaml")"
echo "==> version=$VERSION"

echo "==> build Go engine (android arm64 + armeabi-v7a)"
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

echo "==> flutter build apk --release --split-per-abi"
cd "$ROOT/flutter"
flutter pub get
flutter build apk --release --split-per-abi --target-platform=android-arm,android-arm64

OUT_DIR="$ROOT/flutter/build/app/outputs/flutter-apk"
ARM64_SRC="$OUT_DIR/app-arm64-v8a-release.apk"
ARMV7_SRC="$OUT_DIR/app-armeabi-v7a-release.apk"
[[ -f "$ARM64_SRC" ]] || { echo "missing $ARM64_SRC" >&2; exit 1; }
[[ -f "$ARMV7_SRC" ]] || { echo "missing $ARMV7_SRC" >&2; exit 1; }

mkdir -p "$ROOT/dist"
OUT_AARCH64="$ROOT/dist/KO影视-${VERSION}-aarch64.apk"
OUT_ARMV7="$ROOT/dist/KO影视-${VERSION}-armv7.apk"
cp -f "$ARM64_SRC" "$OUT_AARCH64"
cp -f "$ARMV7_SRC" "$OUT_ARMV7"

echo "==> done:"
ls -lh "$OUT_AARCH64" "$OUT_ARMV7"
