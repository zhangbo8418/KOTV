#!/usr/bin/env bash
# fvp / mdk-sdk：默认从 GitHub Release 拉 v0.38.0，避免 CI 卡在 SourceForge nightly。
# 用法：在 package-*.sh 里 `source "$ROOT/scripts/kotv-fvp-deps.sh"`
# 可选覆盖：FVP_DEPS_URL=https://github.com/wang-bin/mdk-sdk/releases/download/v0.38.0
#
# 注意：fvp 0.37.3 的 podspec 写死 `mdk ~> 0.36.0`（即 >=0.36.0 <0.37.0）。
# 本地 pod 的 s.version 必须写成 0.36.0 才能过 CocoaPods；实际解压的是 0.38.0 SDK。

kotv_fvp_deps_url() {
  echo "${FVP_DEPS_URL:-https://github.com/wang-bin/mdk-sdk/releases/download/v0.38.0}"
}

kotv_mdk_sdk_ver() {
  local url
  url="$(kotv_fvp_deps_url)"
  echo "${url##*/v}"
}

# 导出给 fvp cmake/deps.cmake（Android / Windows / Linux）。
kotv_export_fvp_deps() {
  export FVP_DEPS_URL="$(kotv_fvp_deps_url)"
  echo "==> FVP_DEPS_URL=$FVP_DEPS_URL"
}

# macOS：准备本地 mdk pod（KOTV_MDK_POD_PATH），供 Podfile 使用。
kotv_ensure_mdk_apple_pod() {
  local dest="${KOTV_MDK_POD_PATH:-/tmp/mdk-sdk-local}"
  local tarball="${KOTV_MDK_APPLE_TAR:-/tmp/mdk-sdk-apple.tar.xz}"
  local url ver stamp
  url="$(kotv_fvp_deps_url)/mdk-sdk-apple.tar.xz"
  ver="$(kotv_mdk_sdk_ver)"
  stamp="$dest/.kotv-mdk-sdk"

  mkdir -p "$dest"
  if [[ -f "$stamp" && "$(cat "$stamp" 2>/dev/null)" == "$ver" ]] && { [[ -d "$dest/mdk.xcframework" ]] || [[ -d "$dest/mdk-sdk/lib/mdk.xcframework" ]]; }; then
    kotv_write_mdk_podspec "$dest"
    export KOTV_MDK_POD_PATH="$dest"
    echo "==> mdk apple pod ready ($ver): $KOTV_MDK_POD_PATH"
    return 0
  fi

  echo "==> fetch mdk-sdk-apple $ver: $url"
  curl -fL --retry 5 --retry-delay 2 -o "$tarball" "$url"
  rm -rf "$dest"
  mkdir -p "$dest"
  tar -xJf "$tarball" -C "$dest"
  kotv_write_mdk_podspec "$dest"
  echo "$ver" > "$stamp"
  export KOTV_MDK_POD_PATH="$dest"
  echo "==> mdk apple pod prepared ($ver): $KOTV_MDK_POD_PATH"
}

# fvp 要求 mdk ~> 0.36.0；s.version 用 0.36.0，二进制仍是上面拉到的 SDK。
kotv_write_mdk_podspec() {
  local dest="$1"
  cat > "$dest/mdk.podspec" <<'EOF'
Pod::Spec.new do |s|
  s.name             = 'mdk'
  s.version          = '0.36.0'
  s.summary          = 'Multimedia Development Kit'
  s.homepage         = 'https://github.com/wang-bin/mdk-sdk'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Wang Bin' => 'wbsecg1@gmail.com' }
  s.osx.deployment_target = '10.13'
  s.ios.deployment_target = '12.0'
  s.source           = { :path => '.' }
  s.vendored_frameworks = 'mdk.xcframework'
end
EOF
  if [[ -d "$dest/mdk-sdk/lib/mdk.xcframework" ]]; then
    ln -sfn mdk-sdk/lib/mdk.xcframework "$dest/mdk.xcframework"
    if [[ "$(uname -s)" == "Darwin" ]]; then
      sed -i '' "s|mdk.xcframework|mdk-sdk/lib/mdk.xcframework|" "$dest/mdk.podspec"
    else
      sed -i "s|mdk.xcframework|mdk-sdk/lib/mdk.xcframework|" "$dest/mdk.podspec"
    fi
  fi
}
