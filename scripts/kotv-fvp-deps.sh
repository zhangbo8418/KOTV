#!/usr/bin/env bash
# fvp / mdk-sdk：默认从 GitHub Release 拉，避免 CI 卡在 SourceForge nightly。
# 用法：在 package-*.sh 里 `source "$ROOT/scripts/kotv-fvp-deps.sh"`
# 可选覆盖：FVP_DEPS_URL=https://github.com/wang-bin/mdk-sdk/releases/download/v0.38.0

kotv_fvp_deps_url() {
  echo "${FVP_DEPS_URL:-https://github.com/wang-bin/mdk-sdk/releases/download/v0.38.0}"
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
  local url
  url="$(kotv_fvp_deps_url)/mdk-sdk-apple.tar.xz"

  if [[ -f "$dest/mdk.podspec" ]]; then
    export KOTV_MDK_POD_PATH="$dest"
    echo "==> mdk apple pod ready: $KOTV_MDK_POD_PATH"
    return 0
  fi

  echo "==> fetch mdk-sdk-apple: $url"
  curl -fL --retry 5 --retry-delay 2 -o "$tarball" "$url"
  rm -rf "$dest"
  mkdir -p "$dest"
  tar -xJf "$tarball" -C "$dest"
  cat > "$dest/mdk.podspec" <<'EOF'
Pod::Spec.new do |s|
  s.name             = 'mdk'
  s.version          = '0.38.0'
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
  export KOTV_MDK_POD_PATH="$dest"
  echo "==> mdk apple pod prepared: $KOTV_MDK_POD_PATH"
}
