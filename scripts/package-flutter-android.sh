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
  # Android CI 常用 JDK 17；bridge 默认 toolchain 21 会编出 class 65 导致 smoke 失败
  export KOTV_JAVA_TOOLCHAIN="${KOTV_JAVA_TOOLCHAIN:-17}"
  "$ROOT/bridge/build.sh"
fi

echo "==> flutter build apk --release (per-ABI, no --split-per-abi)"
cd "$ROOT/flutter"
flutter pub get

OUT_DIR="$ROOT/flutter/build/app/outputs/flutter-apk"
mkdir -p "$ROOT/dist"

# Chaquopy 强制要 ndk.abiFilters，不能与 --split-per-abi 并用；分两次单 ABI 构建。
build_one_abi() {
  local abi_filter="$1"   # arm64-v8a | armeabi-v7a
  local flutter_plat="$2" # android-arm64 | android-arm
  local out_name="$3"     # KO影视-…-aarch64.apk
  echo "==> ABI $abi_filter ($flutter_plat)"
  rm -f "$OUT_DIR/app-release.apk"
  KOTV_ABI_FILTERS="$abi_filter" \
    flutter build apk --release --target-platform="$flutter_plat"
  local src="$OUT_DIR/app-release.apk"
  [[ -f "$src" ]] || { echo "missing $src" >&2; exit 1; }
  cp -f "$src" "$ROOT/dist/$out_name"
  ls -lh "$ROOT/dist/$out_name"
}

build_one_abi "arm64-v8a" "android-arm64" "KO影视-${VERSION}-aarch64.apk"
build_one_abi "armeabi-v7a" "android-arm" "KO影视-${VERSION}-armv7.apk"

echo "==> done:"
ls -lh "$ROOT/dist/KO影视-${VERSION}-aarch64.apk" "$ROOT/dist/KO影视-${VERSION}-armv7.apk"
