#!/usr/bin/env bash
# 拉取 TV/webhtv 定制 Media3 + nextlib AV3A Maven 产物（对齐 TV Exo FFmpeg 音轨/AV3A）。
#
# 注意：webhtv 的 media3-*-1.11.0-alpha01-fongmi 二进制缺 DecodeTrackSelector /
# DolbyVisionOutputPolicy。package-flutter-android.sh 会接着跑：
#   ./scripts/build-fongmi-media3.sh
# 用 FongMi/media release-1.11.0-fongmi 覆盖同版本 AAR（本地与 GitHub CI 相同）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/flutter/android/third_party/maven-webhtv"
BASE="${KOTV_WEBHTV_MAVEN_BASE:-https://raw.githubusercontent.com/fish2018/webhtv/main/third_party/maven}"

fetch_maven() {
  local rel="$1"
  local out="$DEST/$rel"
  mkdir -p "$(dirname "$out")"
  if [[ -f "$out" && -s "$out" ]]; then
    echo "ok $rel"
    return
  fi
  echo "GET $BASE/$rel"
  curl -fL --retry 5 --retry-delay 2 -o "$out.partial" "$BASE/$rel"
  mv "$out.partial" "$out"
}

artifacts=(
  "androidx/media3/media3-common/1.11.0-alpha01-fongmi/media3-common-1.11.0-alpha01-fongmi.pom"
  "androidx/media3/media3-common/1.11.0-alpha01-fongmi/media3-common-1.11.0-alpha01-fongmi.aar"
  "androidx/media3/media3-container/1.11.0-alpha01-fongmi/media3-container-1.11.0-alpha01-fongmi.pom"
  "androidx/media3/media3-container/1.11.0-alpha01-fongmi/media3-container-1.11.0-alpha01-fongmi.aar"
  "androidx/media3/media3-database/1.11.0-alpha01-fongmi/media3-database-1.11.0-alpha01-fongmi.pom"
  "androidx/media3/media3-database/1.11.0-alpha01-fongmi/media3-database-1.11.0-alpha01-fongmi.aar"
  "androidx/media3/media3-decoder/1.11.0-alpha01-fongmi/media3-decoder-1.11.0-alpha01-fongmi.pom"
  "androidx/media3/media3-decoder/1.11.0-alpha01-fongmi/media3-decoder-1.11.0-alpha01-fongmi.aar"
  "androidx/media3/media3-exoplayer/1.11.0-alpha01-fongmi/media3-exoplayer-1.11.0-alpha01-fongmi.pom"
  "androidx/media3/media3-exoplayer/1.11.0-alpha01-fongmi/media3-exoplayer-1.11.0-alpha01-fongmi.aar"
  "androidx/media3/media3-extractor/1.11.0-alpha01-fongmi/media3-extractor-1.11.0-alpha01-fongmi.pom"
  "androidx/media3/media3-extractor/1.11.0-alpha01-fongmi/media3-extractor-1.11.0-alpha01-fongmi.aar"
  "androidx/media3/media3-exoplayer-hls/1.11.0-alpha01-fongmi/media3-exoplayer-hls-1.11.0-alpha01-fongmi.pom"
  "androidx/media3/media3-exoplayer-hls/1.11.0-alpha01-fongmi/media3-exoplayer-hls-1.11.0-alpha01-fongmi.aar"
  "androidx/media3/media3-exoplayer-dash/1.11.0-alpha01-fongmi/media3-exoplayer-dash-1.11.0-alpha01-fongmi.pom"
  "androidx/media3/media3-exoplayer-dash/1.11.0-alpha01-fongmi/media3-exoplayer-dash-1.11.0-alpha01-fongmi.aar"
  "androidx/media3/media3-datasource/1.11.0-alpha01-fongmi/media3-datasource-1.11.0-alpha01-fongmi.pom"
  "androidx/media3/media3-datasource/1.11.0-alpha01-fongmi/media3-datasource-1.11.0-alpha01-fongmi.aar"
  "androidx/media3/media3-datasource-okhttp/1.11.0-alpha01-fongmi/media3-datasource-okhttp-1.11.0-alpha01-fongmi.pom"
  "androidx/media3/media3-datasource-okhttp/1.11.0-alpha01-fongmi/media3-datasource-okhttp-1.11.0-alpha01-fongmi.aar"
  "io/github/anilbeesetti/nextlib-media3ext/1.10.0-0.12.1-fongmi-softload-av3a-r1/nextlib-media3ext-1.10.0-0.12.1-fongmi-softload-av3a-r1.pom"
  "io/github/anilbeesetti/nextlib-media3ext/1.10.0-0.12.1-fongmi-softload-av3a-r1/nextlib-media3ext-1.10.0-0.12.1-fongmi-softload-av3a-r1.aar"
)

echo "==> fetch Exo AV3A stack (webhtv maven) → $DEST"
for a in "${artifacts[@]}"; do
  fetch_maven "$a"
done

# nextlib AAR 声明 minCompileSdk=37，但 AGP 8.11 / Flutter 默认 compileSdk=36，且 SDK 37 包未必可用。
# 将元数据降到 36，保留 targetSdk=28（可 exec 社区仓）。
patch_nextlib_aar_sdk() {
  local aar="$DEST/io/github/anilbeesetti/nextlib-media3ext/1.10.0-0.12.1-fongmi-softload-av3a-r1/nextlib-media3ext-1.10.0-0.12.1-fongmi-softload-av3a-r1.aar"
  [[ -f "$aar" ]] || return 0
  local tmp
  tmp="$(mktemp -d)"
  (
    cd "$tmp"
    unzip -q "$aar"
    local meta="META-INF/com/android/build/gradle/aar-metadata.properties"
    if [[ -f "$meta" ]] && grep -q 'minCompileSdk=37' "$meta"; then
      sed 's/minCompileSdk=37/minCompileSdk=36/' "$meta" >"$meta.new"
      mv "$meta.new" "$meta"
      rm -f "$aar"
      zip -qr "$aar" .
      echo "patched nextlib minCompileSdk 37→36"
    else
      echo "ok nextlib aar metadata (no minCompileSdk=37)"
    fi
  )
  rm -rf "$tmp"
}
patch_nextlib_aar_sdk

echo "==> done"
