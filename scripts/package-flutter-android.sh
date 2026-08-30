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

# 钉死 targetSdk：潇洒哥 go 多线程依赖 ≤28；勿落到 Flutter 默认 36。
export KOTV_TARGET_SDK="${KOTV_TARGET_SDK:-28}"
echo "==> KOTV_TARGET_SDK=$KOTV_TARGET_SDK"

chmod +x "$ROOT"/scripts/*.sh

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

# 安卓桥按 Android SDK 编进 App（:kotv-bridge），不打桌面 spider-bridge.jar。
# 桌面/其他平台仍走 bridge/build.sh → JVM shadowJar。

echo "==> flutter build apk --release (per-ABI; Chaquopy 禁用 --split-per-abi)"
cd "$ROOT/flutter"
# shellcheck source=kotv-fvp-deps.sh
source "$ROOT/scripts/kotv-fvp-deps.sh"
kotv_export_fvp_deps
flutter pub get
chmod +x "$ROOT/scripts/patch-android-plugin-namespaces.sh"
"$ROOT/scripts/patch-android-plugin-namespaces.sh"
chmod +x "$ROOT/scripts/fetch-android-mpv-libs.sh"
"$ROOT/scripts/fetch-android-mpv-libs.sh"

echo "==> build libvulkan stub (API 25+ / RK3399)"
for abi in arm64-v8a armeabi-v7a; do
  "$ROOT/scripts/build-android-libvulkan-stub.sh" "$abi"
done

OUT_DIR="$ROOT/flutter/build/app/outputs/flutter-apk"
mkdir -p "$ROOT/dist"

# Chaquopy 强制要 ndk.abiFilters，不能与 --split-per-abi 并用；分两次单 ABI 构建。
# Flutter 3.35+ 默认会塞 armv7+arm64+x86_64：须 -Pdisable-abi-filtering，再靠 KOTV_ABI_FILTERS。
build_one_abi() {
  local abi_filter="$1"   # arm64-v8a | armeabi-v7a
  local flutter_plat="$2" # android-arm64 | android-arm
  local out_name="$3"     # KO影视-…-aarch64.apk
  echo "==> ABI $abi_filter ($flutter_plat)"
  rm -f "$OUT_DIR/app-release.apk"
  KOTV_ABI_FILTERS="$abi_filter" \
    flutter build apk --release \
      --target-platform="$flutter_plat" \
      -Pdisable-abi-filtering=true
  local src="$OUT_DIR/app-release.apk"
  [[ -f "$src" ]] || { echo "missing $src" >&2; exit 1; }
  # 校验：整包不得残留其它 ABI（lib/ + assets/chaquopy 等）
  local listing libs
  listing="$(unzip -l "$src" | awk 'NR>3 {print $4}')"
  libs="$(printf '%s\n' "$listing" | awk -F/ '/^lib\//{print $2}' | sort -u | tr '\n' ' ')"
  echo "  lib ABIs in apk: $libs"
  case " $libs " in
    *" ${abi_filter} "*) ;;
    *) echo "ERROR: apk missing lib/$abi_filter" >&2; exit 1 ;;
  esac
  if ! printf '%s\n' "$listing" | python3 -c '
import re, sys
want = sys.argv[1]
others = [a for a in ("x86_64", "armeabi-v7a", "arm64-v8a", "x86") if a != want]
hits = []
for line in sys.stdin:
    p = line.strip()
    if not p or p.endswith("/"):
        continue
    parts = p.split("/")
    # 只认 Android JNI：lib/<abi>/...；不要把 darwin/x86_64、win/x86 当 ABI
    if len(parts) >= 2 and parts[0] == "lib" and parts[1] in others:
        hits.append(p)
        continue
    # Chaquopy：assets 里带 ABI 后缀的 zip/so
    if "chaquopy" in p.lower():
        for a in others:
            if a == "x86" and "x86_64" in p:
                continue
            if re.search(rf"(^|[-_./]){re.escape(a)}([.-_/]|$)", p):
                hits.append(p)
                break
if hits:
    print("\n".join(hits[:40]), file=sys.stderr)
    if len(hits) > 40:
        print(f"... and {len(hits) - 40} more", file=sys.stderr)
    sys.exit(1)
' "$abi_filter"
  then
    echo "ERROR: apk contains foreign ABI paths (want only $abi_filter)" >&2
    exit 1
  fi
  cp -f "$src" "$ROOT/dist/$out_name"
  ls -lh "$ROOT/dist/$out_name"
  # 校验 targetSdk（须为 KOTV_TARGET_SDK，默认 28）
  if command -v aapt >/dev/null 2>&1 || [[ -n "${ANDROID_HOME:-}" ]]; then
    local aapt_bin=""
    if command -v aapt >/dev/null 2>&1; then
      aapt_bin=aapt
    else
      aapt_bin="$(ls -1 "$ANDROID_HOME"/build-tools/*/aapt 2>/dev/null | tail -1 || true)"
    fi
    if [[ -n "$aapt_bin" && -x "$aapt_bin" ]]; then
      local badging target
      badging="$("$aapt_bin" dump badging "$ROOT/dist/$out_name" 2>/dev/null || true)"
      target="$(printf '%s\n' "$badging" | sed -n "s/.*targetSdkVersion:'\\([^']*\\)'.*/\\1/p" | head -1)"
      echo "  targetSdkVersion=$target (want $KOTV_TARGET_SDK)"
      if [[ -n "$target" && "$target" != "$KOTV_TARGET_SDK" ]]; then
        echo "ERROR: targetSdkVersion=$target, expected $KOTV_TARGET_SDK" >&2
        exit 1
      fi
    fi
  fi
}

build_one_abi "arm64-v8a" "android-arm64" "KO影视-${VERSION}-aarch64.apk"
build_one_abi "armeabi-v7a" "android-arm" "KO影视-${VERSION}-armv7.apk"

echo "==> done:"
ls -lh "$ROOT/dist/KO影视-${VERSION}-aarch64.apk" "$ROOT/dist/KO影视-${VERSION}-armv7.apk"
