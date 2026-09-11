#!/usr/bin/env bash
# 安卓 libmpv / FFmpeg / libplayer JNI 从源码编。
# webhtv 只提供交叉编译脚本、补丁与 JNI 源码；FFmpeg 跟 FongMi release-9.0-fongmi tip（RELEASE=9.0.1）。
# CI 不下载预编译 .so，也不提交 .so。
#
# 现网功能：aaudio android android-media-ndk audiotrack egl-android ffmpeg gl
#   iconv libarchive libass libavdevice libbluray dvdnav libcurl libplacebo lua
#   opensles rubberband uchardet vulkan + AV3A。
# 伪装成 .png/.jpg 的 HLS 分片由播放器 demuxer-lavf-o（extension_picky=0）处理。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WEBHTV_REF="${KOTV_WEBHTV_MPV_PIN:-${KOTV_WEBHTV_MPV_REF:-main}}"
FFMPEG_REPO="${KOTV_FFMPEG_REPO:-https://github.com/FongMi/FFmpeg.git}"
FFMPEG_REF="${KOTV_FFMPEG_REF:-release-9.0-fongmi}"
WORK="${KOTV_ANDROID_MPV_SRC:-$ROOT/.build/android-mpv-src}"
ASSET="$ROOT/flutter/android/app/src/main/assets/mpv-libs"
STAMP="$ASSET/.kotv-source-build"
JOBS="${KOTV_MPV_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

need() { command -v "$1" >/dev/null || { echo "need $1" >&2; exit 1; }; }
for cmd in git curl python3 pkg-config perl cmake gperf make; do
  need "$cmd"
done

resolve_ffmpeg_sha() {
  if [[ -n "${KOTV_FFMPEG_COMMIT:-}" ]]; then
    printf '%s\n' "$KOTV_FFMPEG_COMMIT"
    return
  fi
  local sha
  sha="$(git ls-remote "$FFMPEG_REPO" "refs/heads/${FFMPEG_REF}" | awk '{print $1; exit}')"
  [[ -n "$sha" ]] || { echo "ERROR: cannot resolve $FFMPEG_REPO $FFMPEG_REF" >&2; exit 1; }
  printf '%s\n' "$sha"
}

FFMPEG_COMMIT="$(resolve_ffmpeg_sha)"
want="webhtv=${WEBHTV_REF} ffmpeg=${FFMPEG_COMMIT:0:12}"
jni="$ROOT/flutter/android/app/src/main/jniLibs"
has_suite() {
  local abi="$1" dir="$2"
  [[ -s "$dir/$abi/libmpv.so" && -s "$dir/$abi/libplayer.so" && -s "$dir/$abi/libmvcodec.so" ]]
}
if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$want" ]] && has_suite arm64-v8a "$ASSET" && has_suite armeabi-v7a "$ASSET"; then
  echo "ok cached Android MPV source build ($want)"
  exit 0
fi
if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$want" ]] && has_suite arm64-v8a "$jni" && has_suite armeabi-v7a "$jni"; then
  echo "ok cached Android MPV already in jniLibs ($want)"
  exit 0
fi

echo "==> clone webhtv $WEBHTV_REF (builder only; FFmpeg → ${FFMPEG_REF} ${FFMPEG_COMMIT:0:12})"
mkdir -p "$WORK"
if [[ ! -d "$WORK/webhtv/.git" ]]; then
  git clone --filter=blob:none --depth 1 https://github.com/fish2018/webhtv.git "$WORK/webhtv"
fi
git -C "$WORK/webhtv" fetch --depth 1 origin "$WEBHTV_REF"
git -C "$WORK/webhtv" checkout -q FETCH_HEAD 2>/dev/null \
  || git -C "$WORK/webhtv" checkout -q "$WEBHTV_REF"

# 覆盖 webhtv 锁里的 FFmpeg：跟 FongMi 9.0.1 分支 tip，不跟它仓库里钉死的旧提交。
python3 - "$WORK/webhtv/third_party/mpv-native-lock.json" "$FFMPEG_REPO" "$FFMPEG_COMMIT" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
ff = data.setdefault("sources", {}).setdefault("ffmpeg", {})
ff["repo"] = sys.argv[2]
ff["commit"] = sys.argv[3]
ff["version"] = "9.0.1-fongmi-tip"
path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
print(f"ok lock ffmpeg → {sys.argv[3][:12]}")
PY

build_sh="$WORK/webhtv/scripts/build_mpv_native.sh"
chmod +x "$build_sh"

# webhtv 锁的是 NDK r29。CI 给 kotv_dl 用的 r28c 不能拿来编这套。
ensure_ndk29() {
  local want="29.0.14206865"
  local sdk="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
  if [[ -z "$sdk" && -d "$HOME/Android/Sdk" ]]; then
    sdk="$HOME/Android/Sdk"
  elif [[ -z "$sdk" && -d "$HOME/Library/Android/sdk" ]]; then
    sdk="$HOME/Library/Android/sdk"
  fi
  local ndk="${sdk}/ndk/${want}"
  if [[ ! -f "$ndk/source.properties" ]] || ! grep -q "Pkg.Revision = $want" "$ndk/source.properties"; then
    command -v sdkmanager >/dev/null || { echo "ERROR: need Android NDK $want (sdkmanager missing)" >&2; exit 1; }
    yes | sdkmanager --licenses >/dev/null || true
    sdkmanager "ndk;${want}"
  fi
  [[ -f "$ndk/source.properties" ]] || { echo "ERROR: NDK $want not at $ndk" >&2; exit 1; }
  printf '%s\n' "$ndk"
}

NDK29="$(ensure_ndk29)"
echo "==> build Android FFmpeg + mpv + libplayer JNI (arm64-v8a + armeabi-v7a), jobs=$JOBS"
echo "    NDK=$NDK29"
(
  export ANDROID_NDK_HOME="$NDK29"
  cd "$WORK/webhtv"
  ./scripts/build_mpv_native.sh --abi all --install --jobs "$JOBS" --work-dir "$WORK/build"
  ./scripts/build_mpv_player_jni.sh --abi all --install --work-dir "$WORK/build"
)

copy_abi() {
  local flavor="$1" abi="$2"
  local src="$WORK/webhtv/app/src/$flavor/assets/mpv-libs/$abi"
  local dest="$ASSET/$abi"
  mkdir -p "$dest"
  [[ -s "$src/libmpv.so" ]] || { echo "ERROR: missing $src/libmpv.so" >&2; exit 1; }
  local lib
  for lib in libc++_shared.so libmvutil.so libmwresample.so libmwscale.so \
      libmvcodec.so libmvformat.so libmvfilter.so libmvdevice.so \
      libmpv.so libplayer.so; do
    [[ -s "$src/$lib" ]] || { echo "ERROR: missing $src/$lib" >&2; exit 1; }
    cp -f "$src/$lib" "$dest/$lib"
  done
  if ! grep -aq 'libcurl' "$dest/libmpv.so"; then
    echo "ERROR: $abi/libmpv.so built without libcurl" >&2
    exit 1
  fi
  if ! grep -aqE 'vulkan|androidvk' "$dest/libmpv.so"; then
    echo "ERROR: $abi/libmpv.so lacks vulkan" >&2
    exit 1
  fi
  if ! grep -aqE 'libarcdav3a|AV3A Audio Vivid' "$dest/libmvcodec.so"; then
    echo "ERROR: $abi/libmvcodec.so lacks AV3A" >&2
    exit 1
  fi
  if ! grep -aq 'dvdnav' "$dest/libmpv.so" || ! grep -aq 'libbluray' "$dest/libmpv.so"; then
    echo "ERROR: $abi/libmpv.so lacks DVD/Blu-ray ISO (dvdnav + libbluray)" >&2
    exit 1
  fi
  echo "ok $abi source libmpv $(wc -c <"$dest/libmpv.so" | tr -d ' ') bytes"
}

copy_abi arm64_v8a arm64-v8a
copy_abi armeabi_v7a armeabi-v7a
printf '%s\n' "$want" >"$STAMP"
echo "==> Android MPV source build staged at $ASSET"
