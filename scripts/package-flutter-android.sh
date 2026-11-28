#!/usr/bin/env bash
# 打包 Flutter Android：按 ABI 拆包
#   dist/KO影视-{version}-aarch64.apk
#   dist/KO影视-{version}-armv7.apk
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=kotv-release-name.sh
source "$ROOT/scripts/kotv-release-name.sh"
export PATH="${HOME}/flutter/bin:${PATH}"
# 本地默认国内镜像；GitHub Actions 用官方源（镜像偶发 content-hash 失败）。
if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
  export PUB_HOSTED_URL="${PUB_HOSTED_URL:-https://pub.dev}"
  export FLUTTER_STORAGE_BASE_URL="${FLUTTER_STORAGE_BASE_URL:-https://storage.googleapis.com}"
else
  export PUB_HOSTED_URL="${PUB_HOSTED_URL:-https://pub.flutter-io.cn}"
  export FLUTTER_STORAGE_BASE_URL="${FLUTTER_STORAGE_BASE_URL:-https://storage.flutter-io.cn}"
fi

VERSION="$(kotv_release_version "$ROOT/flutter/pubspec.yaml")"
kotv_check_version_literals "$VERSION"
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
  echo "==> thunder-release.aar missing; copy from sibling repo if available"
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
# 安卓不编 fvp/mdk，无需拉 mdk-sdk（桌面/iOS 仍走 kotv-fvp-deps.sh）。
KOTV_FLUTTER_TARGET=android "$ROOT/scripts/flutter-pub-get.sh"
chmod +x "$ROOT/scripts/kotv-exclude-fvp-plugin.sh"
"$ROOT/scripts/kotv-exclude-fvp-plugin.sh" android
chmod +x "$ROOT/scripts/patch-android-plugin-namespaces.sh"
"$ROOT/scripts/patch-android-plugin-namespaces.sh"
echo "==> fetch Exo AV3A stack (nextlib + Media3)"
chmod +x "$ROOT/scripts/fetch-android-exo-av3a.sh"
"$ROOT/scripts/fetch-android-exo-av3a.sh"
# webhtv 二进制缺 DecodeTrackSelector / DolbyVisionOutputPolicy；用 build-fongmi-media3.sh 覆盖。
chmod +x "$ROOT/scripts/build-fongmi-media3.sh"
"$ROOT/scripts/build-fongmi-media3.sh"
chmod +x "$ROOT/scripts/prepare-android-mpv-native.sh"
"$ROOT/scripts/prepare-android-mpv-native.sh"
chmod +x "$ROOT/scripts/build-android-node-launcher.sh"
echo "==> build Android Node launcher (libkotv_node.so + libnode.so)"
"$ROOT/scripts/build-android-node-launcher.sh"
for _abi in arm64-v8a armeabi-v7a; do
  for _so in libkotv_node.so libnode.so; do
    if [[ ! -f "$ROOT/flutter/android/app/src/main/jniLibs/$_abi/$_so" ]]; then
      echo "ERROR: missing jniLibs/$_abi/$_so after node launcher build" >&2
      exit 1
    fi
  done
done

OUT_DIR="$ROOT/flutter/build/app/outputs/flutter-apk"
mkdir -p "$ROOT/dist"
# shellcheck source=kotv-flutter-asset-engines.sh
source "$ROOT/scripts/kotv-flutter-asset-engines.sh"
kotv_flutter_asset_engines_hide
trap kotv_flutter_asset_engines_restore EXIT

# Chaquopy 强制要 ndk.abiFilters，不能与 --split-per-abi 并用；分两次单 ABI 构建。
# Flutter 3.35+ 默认会塞 armv7+arm64+x86_64：须 -Pdisable-abi-filtering，再靠 KOTV_ABI_FILTERS。
build_one_abi() {
  local abi_filter="$1"   # arm64-v8a | armeabi-v7a
  local flutter_plat="$2" # android-arm64 | android-arm
  local out_name="$3"     # KO影视-…-aarch64.apk
  echo "==> ABI $abi_filter ($flutter_plat)"
  rm -f "$OUT_DIR/app-release.apk"
  # pub get / 工具链可能写回插件列表；每次 build 前再排除一次。
  "$ROOT/scripts/kotv-exclude-fvp-plugin.sh" android
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
  kotv_flutter_asset_engines_reject "$src"
  case " $libs " in
    *" ${abi_filter} "*) ;;
    *) echo "ERROR: apk missing lib/$abi_filter" >&2; exit 1 ;;
  esac
  for _so in libkotv_node.so libnode.so; do
    if ! printf '%s\n' "$listing" | grep -qx "lib/${abi_filter}/${_so}"; then
      echo "ERROR: apk missing lib/${abi_filter}/${_so}" >&2
      exit 1
    fi
  done
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
    # 只认 Android JNI：lib/<abi>/...；不要把 darwin/x86_64、win/x86 当 ABI。
    # assets/ 由 aapt 打入，packaging.resources.excludes 删不掉，留给后面的 tidy。
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
  "$ROOT/scripts/tidy-android-apk.sh" "$ROOT/dist/$out_name" "$abi_filter"
  ls -lh "$ROOT/dist/$out_name"
  "$ROOT/scripts/verify-android-mpv-apk.sh" "$ROOT/dist/$out_name"
  "$ROOT/scripts/verify-android-apk-tidy.sh" "$ROOT/dist/$out_name" "$abi_filter"
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
