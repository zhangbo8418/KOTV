#!/usr/bin/env bash
# 未签名 iOS IPA。flutter build ipa --no-codesign 不会导出 IPA，
# 且归档产物里的动态库经常是指向 DerivedData 的符号链接，zip -y 会把链接打进包、真身留在外面。
# 这里把设备端框架收成包内的实体文件，缺 mdk / App 或 Runner 未静态链入 libmpv 就失败。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=kotv-release-name.sh
source "$ROOT/scripts/kotv-release-name.sh"
# shellcheck source=kotv-flutter-asset-engines.sh
source "$ROOT/scripts/kotv-flutter-asset-engines.sh"
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
  export PUB_HOSTED_URL="${PUB_HOSTED_URL:-https://pub.dev}"
  export FLUTTER_STORAGE_BASE_URL="${FLUTTER_STORAGE_BASE_URL:-https://storage.googleapis.com}"
  # shellcheck source=kotv-select-xcode.sh
  source "$ROOT/scripts/kotv-select-xcode.sh"
  kotv_select_newest_xcode
  xcodebuild -showsdks | awk '/iphoneos/ { print }'
fi

kotv_ios_macho() {
  local bin="$1"
  [[ -f "$bin" && ! -L "$bin" ]] || return 1
  file -b "$bin" | grep -q 'Mach-O'
}

kotv_ios_framework_ok() {
  local app="$1" name="$2"
  local dest="$app/Frameworks/${name}.framework"
  [[ -d "$dest" && ! -L "$dest" ]] || return 1
  kotv_ios_macho "$dest/$name"
}

# 指向 App 外面的符号链接换成实体文件。包内的 Versions 链接保留。
kotv_ios_materialize_outside_links() {
  local app="$1"
  local link resolved
  while IFS= read -r link; do
    [[ -n "$link" ]] || continue
    resolved="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$link" 2>/dev/null || true)"
    [[ -n "$resolved" && -e "$resolved" ]] || continue
    python3 -c 'import os,sys; root,path=os.path.realpath(sys.argv[1]),os.path.realpath(sys.argv[2]); raise SystemExit(0 if path==root or path.startswith(root+os.sep) else 1)' "$app" "$resolved" && continue
    rm -rf "$link"
    if [[ -d "$resolved" ]]; then
      cp -R "$resolved" "$link"
    else
      cp -L "$resolved" "$link"
    fi
  done < <(find "$app" -type l | awk '{ print length, $0 }' | sort -nr | cut -d' ' -f2-)
}

kotv_ios_copy_framework() {
  local src="$1" dest_parent="$2"
  local name dest
  name="$(basename "$src")"
  dest="$dest_parent/$name"
  rm -rf "$dest"
  mkdir -p "$dest_parent"
  cp -R "$src" "$dest"
}

# 只收 ios-arm64，避开模拟器切片。
kotv_ios_device_slices() {
  local root name parent
  for root in "$@"; do
    [[ -d "$root" ]] || continue
    while IFS= read -r fw; do
      [[ -n "$fw" ]] || continue
      parent="$(basename "$(dirname "$fw")")"
      [[ "$parent" == "ios-arm64" ]] || continue
      echo "$fw"
    done < <(find "$root" -type d -name '*.framework' 2>/dev/null || true)
  done
}

kotv_ios_built_framework() {
  local name="$1"
  shift
  local fw hit=""
  for root in "$@"; do
    [[ -d "$root" ]] || continue
    while IFS= read -r fw; do
      [[ -n "$fw" ]] || continue
      case "$fw" in
        *simulator*|*iphonesimulator*) continue ;;
        *iphoneos*) ;;
        *) continue ;;
      esac
      [[ -e "$fw/$name" ]] || continue
      if [[ "$fw" == *Release-iphoneos* ]]; then
        echo "$fw"
        return 0
      fi
      hit="$fw"
    done < <(find "$root" -type d -name "${name}.framework" 2>/dev/null || true)
  done
  [[ -n "$hit" ]] && echo "$hit"
}

kotv_ios_prepare_app() {
  local app="$1"
  local fw name built
  kotv_ios_materialize_outside_links "$app"
  local -a slice_roots=(
    "${KOTV_MDK_POD_PATH:-}"
    "$ROOT/flutter/ios/.symlinks/plugins"
    "$ROOT/flutter/ios/Pods"
  )
  while IFS= read -r fw; do
    [[ -n "$fw" ]] || continue
    name="$(basename "$fw" .framework)"
    if kotv_ios_framework_ok "$app" "$name"; then
      continue
    fi
    echo "==> embed device framework $name"
    kotv_ios_copy_framework "$fw" "$app/Frameworks"
  done < <(kotv_ios_device_slices "${slice_roots[@]}")

  local -a built_roots=(
    "$ROOT/flutter/build/ios"
    "$HOME/Library/Developer/Xcode/DerivedData"
  )
  local -a built_names=(
    file_selector_ios
    fvp
    package_info_plus
    shared_preferences_foundation
    url_launcher_ios
    video_player_avfoundation
    wakelock_plus
  )
  for name in "${built_names[@]}"; do
    if kotv_ios_framework_ok "$app" "$name"; then
      continue
    fi
    built="$(kotv_ios_built_framework "$name" "${built_roots[@]}" || true)"
    if [[ -z "$built" ]]; then
      echo "error: built iOS framework not found: $name" >&2
      return 1
    fi
    echo "==> embed built framework $name"
    kotv_ios_copy_framework "$built" "$app/Frameworks"
  done

  local -a required=(App Flutter mdk fvp)
  for name in "${required[@]}"; do
    if ! kotv_ios_framework_ok "$app" "$name"; then
      echo "error: $app is missing a real $name.framework" >&2
      return 1
    fi
  done
  echo "==> iOS app frameworks:"
  find "$app/Frameworks" -maxdepth 1 -type d -name '*.framework' -exec basename {} \; | sort
  kotv_ios_strip_unused_assets "$app"
  du -sh "$app" "$app/Frameworks"
}

# iOS 没有本地引擎。assets/engine 只剩占位说明；网页脚本在 iOS 上也不加载。
# 删掉文件后再清因此变空的目录，避免包里留下空文件夹。
kotv_ios_strip_unused_assets() {
  local app="$1"
  local assets="$app/Frameworks/App.framework/flutter_assets"
  [[ -d "$assets" ]] || return 0
  kotv_flutter_strip_placeholder_assets "$assets"
}

# Xcode 工程里 MPVKit 钉的提交必须与 mpv-build.lock.json 相同（桌面补丁同源）。
kotv_ios_check_mpvkit_pin() {
  local want pbx
  want="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["commit"])' "$ROOT/mpv-build.lock.json")"
  pbx="$ROOT/flutter/ios/Runner.xcodeproj/project.pbxproj"
  if ! grep -q "revision = ${want};" "$pbx"; then
    echo "error: $pbx does not pin MPVKit (edde746/mpv-build) to ${want}" >&2
    grep -n "revision = " "$pbx" >&2 || true
    return 1
  fi
  echo "ok MPVKit pinned to ${want:0:12}"
}

# MPVKit 是静态库，链进 Runner 主程序（Frameworks 里同名 Lib*.framework 是 Xcode 留的空壳）；
# 查 avfoundation 输出、MoltenVK 与 VideoToolbox 杜比视界补丁的字符串。
kotv_ios_require_libmpv() {
  local app="$1" bin
  bin="$app/Runner"
  local needle
  for needle in \
    "AVFoundation AVSampleBufferDisplayLayer" \
    "-Dmoltenvk=enabled" \
    "Converting Dolby Vision profile 7 to profile 8.1 for VideoToolbox."; do
    if ! strings "$bin" | grep -F -- "$needle" >/dev/null; then
      echo "error: $bin lacks libmpv/FFmpeg string: $needle" >&2
      return 1
    fi
  done
  echo "ok libmpv (avfoundation + VideoToolbox Dolby Vision) linked into Runner"
}

kotv_ios_require_ipa_entry() {
  local ipa="$1" path="$2" min="$3"
  local size
  size="$(unzip -l "$ipa" | awk -v p="$path" '$4 == p && !seen { print $1; seen=1 }')"
  if [[ -z "${size:-}" || "$size" -lt "$min" ]]; then
    echo "error: IPA missing $path (size=${size:-0}, need >= $min)" >&2
    unzip -l "$ipa" | awk '$4 ~ /Frameworks/ { print }' >&2 || true
    return 1
  fi
}

main() {
  if ! command -v pod >/dev/null 2>&1; then
    brew install cocoapods
  fi
  pod --version

  kotv_ios_check_mpvkit_pin
  flutter config --no-enable-swift-package-manager || true
  # 须先 pub get：本地 mdk.podspec 的 s.version 要从 fvp darwin podspec 的
  # `mdk ~> X.Y` 下限写入；先拉最新 SDK 再 pub get 会把 version 写成 0.40.x，
  # 与 fvp 仍声明的 ~> 0.39.0 冲突（CocoaPods）。
  KOTV_FLUTTER_TARGET=ios "$ROOT/scripts/flutter-pub-get.sh"
  # shellcheck source=kotv-fvp-deps.sh
  source "$ROOT/scripts/kotv-fvp-deps.sh"
  kotv_ensure_mdk_apple_pod
  export KOTV_MDK_POD_PATH

  cd "$ROOT/flutter"
  kotv_flutter_asset_engines_hide
  trap kotv_flutter_asset_engines_restore EXIT
  flutter build ipa --no-codesign
  local app="build/ios/archive/Runner.xcarchive/Products/Applications/Runner.app"
  [[ -d "$app" ]] || {
    echo "error: missing $app" >&2
    exit 1
  }
  kotv_ios_prepare_app "$ROOT/flutter/$app"
  kotv_ios_require_libmpv "$ROOT/flutter/$app"

  local ver stage out
  ver="$(kotv_release_version "$ROOT/flutter/pubspec.yaml")"
  stage="$(mktemp -d)"
  mkdir -p "$stage/Payload" "$ROOT/dist"
  ditto "$ROOT/flutter/$app" "$stage/Payload/Runner.app"
  out="$ROOT/dist/KO影视-${ver}-ios.ipa"
  rm -f "$out"
  # -D：不把目录本身写进 zip。文件还在，空目录项不会再出现。
  (cd "$stage" && zip -r -y -D -q "$out" Payload)
  cp -f "$out" "$ROOT/KO影视-${ver}-ios.ipa"
  ls -lh "$out"
  kotv_ios_require_ipa_entry "$out" "Payload/Runner.app/Frameworks/App.framework/App" 5000000
  kotv_ios_require_ipa_entry "$out" "Payload/Runner.app/Frameworks/Flutter.framework/Flutter" 1000000
  kotv_ios_require_ipa_entry "$out" "Payload/Runner.app/Frameworks/mdk.framework/mdk" 1000000
  kotv_ios_require_ipa_entry "$out" "Payload/Runner.app/Frameworks/fvp.framework/fvp" 50000
  kotv_ios_require_ipa_entry "$out" "Payload/Runner.app/Runner" 20000000
  kotv_flutter_asset_engines_reject "$out"
  kotv_ios_reject_asset_clutter "$out"
}

kotv_ios_reject_asset_clutter() {
  local ipa="$1"
  python3 - "$ipa" <<'PY'
import sys, zipfile
ipa = sys.argv[1]
bad = []
with zipfile.ZipFile(ipa) as z:
    for info in z.infolist():
        name = info.filename
        if name.endswith("/") or info.is_dir():
            bad.append("dir " + name)
            continue
        if "flutter_assets/assets/engine/" in name:
            bad.append(name)
        elif name.endswith("/hls1.4.10.js") or name.endswith("/no_sleep.js"):
            bad.append(name)
if bad:
    print("\n".join(bad[:40]), file=sys.stderr)
    sys.exit(1)
print(f"ok: {ipa} has no engine dir, web assets, or empty directory entries")
PY
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
