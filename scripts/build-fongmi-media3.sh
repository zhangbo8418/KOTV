#!/usr/bin/env bash
# 从 FongMi/media (release-1.11.0-fongmi) 编译 Media3，覆盖 maven-webhtv 残缺产物。
# 补齐 DecodeTrackSelector / DolbyVisionOutputPolicy 等 API。
#
# 本地与 CI：package-flutter-android.sh 在 fetch-android-exo-av3a.sh 之后调用本脚本。
# 已含完整 API 时跳过（可用 KOTV_FORCE_FONGMI_MEDIA3=1 强制重编）。
#
# 上游缺 smbj 等 POM 类型声明、且全量模块依赖 test-utils；须先打
# scripts/patches/fongmi-media3-kotv.patch（与本地成功 publish 时一致）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${KOTV_FONGMI_MEDIA:-$ROOT/.tmp/fongmi-media}"
DEST="$ROOT/flutter/android/third_party/maven-webhtv"
VER="1.11.0-alpha01-fongmi"
BRANCH="${KOTV_FONGMI_MEDIA_BRANCH:-release-1.11.0-fongmi}"
REPO_URL="${KOTV_FONGMI_MEDIA_URL:-https://github.com/FongMi/media.git}"
PATCH="$ROOT/scripts/patches/fongmi-media3-kotv.patch"

exo_aar="$DEST/androidx/media3/media3-exoplayer/$VER/media3-exoplayer-$VER.aar"
common_aar="$DEST/androidx/media3/media3-common/$VER/media3-common-$VER.aar"

media3_has_tv_apis() {
  [[ -f "$exo_aar" && -f "$common_aar" ]] || return 1
  local tmp rc=1
  tmp="$(mktemp -d)"
  set +e
  unzip -q -o "$exo_aar" classes.jar -d "$tmp/exo" \
    && unzip -q -o "$common_aar" classes.jar -d "$tmp/common" \
    && jar tf "$tmp/exo/classes.jar" | grep -q DecodeTrackSelector \
    && jar tf "$tmp/common/classes.jar" | grep -q DolbyVisionOutputPolicy
  rc=$?
  set -e
  rm -rf "$tmp"
  return "$rc"
}

if [[ "${KOTV_FORCE_FONGMI_MEDIA3:-0}" != "1" ]] && media3_has_tv_apis; then
  echo "ok FongMi Media3 $VER already has DecodeTrackSelector + DolbyVisionOutputPolicy"
  exit 0
fi

[[ -f "$PATCH" ]] || { echo "ERROR: missing $PATCH" >&2; exit 1; }

prepare_fongmi_src() {
  if [[ ! -d "$SRC/.git" ]]; then
    echo "==> clone FongMi/media ($BRANCH) → $SRC"
    mkdir -p "$(dirname "$SRC")"
    rm -rf "$SRC"
    git clone --filter=blob:none --depth 1 -b "$BRANCH" "$REPO_URL" "$SRC"
  else
    echo "==> refresh FongMi/media ($BRANCH) → $SRC"
    git -C "$SRC" fetch --depth 1 origin "$BRANCH"
    git -C "$SRC" reset --hard FETCH_HEAD
    git -C "$SRC" clean -fd
  fi
  echo "==> apply KOTV patch (smbj POM + module subset)"
  git -C "$SRC" apply "$PATCH"
  # Ensure version coordinate matches KOTV
  if ! grep -q "releaseVersion = \"$VER\"" "$SRC/gradle/libs.versions.toml" 2>/dev/null; then
    perl -i -pe "s/^releaseVersion = \".*\"/releaseVersion = \"$VER\"/" "$SRC/gradle/libs.versions.toml"
  fi
}

prepare_fongmi_src

# JDK：macOS 优先 17；CI / Linux 用 JAVA_HOME 或 PATH 里的 java。
if [[ -z "${JAVA_HOME:-}" ]]; then
  if [[ "$(uname -s)" == "Darwin" ]] && command -v /usr/libexec/java_home >/dev/null 2>&1; then
    export JAVA_HOME="$(/usr/libexec/java_home -v 17 2>/dev/null || /usr/libexec/java_home 2>/dev/null || true)"
  elif command -v java >/dev/null 2>&1; then
    _java="$(readlink -f "$(command -v java)" 2>/dev/null || command -v java)"
    export JAVA_HOME="$(cd "$(dirname "$_java")/.." && pwd)"
  fi
fi
export ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
[[ -n "${JAVA_HOME:-}" ]] || { echo "ERROR: JAVA_HOME (JDK 17+) required" >&2; exit 1; }
[[ -d "$ANDROID_HOME" ]] || { echo "ERROR: ANDROID_HOME missing ($ANDROID_HOME)" >&2; exit 1; }

# Gradle 需要 sdk.dir
printf 'sdk.dir=%s\n' "$ANDROID_HOME" >"$SRC/local.properties"

cd "$SRC"
echo "==> publish FongMi Media3 $VER → $DEST"
./gradlew \
  :lib-common:publishReleasePublicationToMavenRepository \
  :lib-container:publishReleasePublicationToMavenRepository \
  :lib-database:publishReleasePublicationToMavenRepository \
  :lib-decoder:publishReleasePublicationToMavenRepository \
  :lib-datasource:publishReleasePublicationToMavenRepository \
  :lib-datasource-okhttp:publishReleasePublicationToMavenRepository \
  :lib-extractor:publishReleasePublicationToMavenRepository \
  :lib-exoplayer:publishReleasePublicationToMavenRepository \
  :lib-exoplayer-hls:publishReleasePublicationToMavenRepository \
  :lib-exoplayer-dash:publishReleasePublicationToMavenRepository \
  -PmavenRepo="$DEST" \
  -x test -x lint \
  --no-daemon

media3_has_tv_apis || {
  echo "ERROR: published Media3 missing DecodeTrackSelector / DolbyVisionOutputPolicy" >&2
  exit 1
}
echo "==> ok: DecodeTrackSelector + DolbyVisionOutputPolicy present"
