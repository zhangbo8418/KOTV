#!/usr/bin/env bash
# 安卓 libmpv / FFmpeg / libplayer JNI 从源码编。
# 宿主：FongMi/mpv-android（fongmi），产物为合并的 libffmpeg.so + libmpv.so + libplayer.so。
# 默认解析上游 tip：FFmpeg=release-9.1-fongmi，mpv/mpv-android/libplacebo=fongmi；
# KOTV_*_COMMIT 可覆盖做可复现构建。CI 不下载预编译 .so，也不提交 .so。
#
# 现网能力（跟 FongMi buildscripts）：opengl/vulkan/shaderc/libass/libcurl/libbluray/
#   dvdnav/libarchive/rubberband + FFmpeg AV3A(libarcdav3a) + DoVi RPU（libffmpeg 内）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/kotv-win-build-env.sh
source "$ROOT/scripts/kotv-win-build-env.sh"
# shellcheck source=scripts/kotv-resolve-git-ref.sh
source "$ROOT/scripts/kotv-resolve-git-ref.sh"

FFMPEG_REPO="${KOTV_FFMPEG_REPO:-https://github.com/FongMi/FFmpeg.git}"
FFMPEG_REF="${KOTV_FFMPEG_REF:-release-9.1-fongmi}"
MPV_REPO="${KOTV_MPV_REPO:-https://github.com/FongMi/mpv.git}"
MPV_REF="${KOTV_MPV_REF:-fongmi}"
MPV_ANDROID_REPO="${KOTV_MPV_ANDROID_REPO:-https://github.com/FongMi/mpv-android.git}"
MPV_ANDROID_REF="${KOTV_MPV_ANDROID_REF:-fongmi}"
LIBPLACEBO_REPO="${KOTV_LIBPLACEBO_REPO:-https://github.com/FongMi/libplacebo.git}"
LIBPLACEBO_REF="${KOTV_LIBPLACEBO_REF:-fongmi}"
WORK="${KOTV_ANDROID_MPV_SRC:-$ROOT/.build/android-mpv-src}"
ASSET="$ROOT/flutter/android/app/src/main/assets/mpv-libs"
STAMP="$ASSET/.kotv-source-build"
ARCHES="${KOTV_ANDROID_MPV_ARCHES:-armv7l arm64}"

for cmd in git curl python3 pkg-config perl cmake gperf make wget tar; do
  if ! command -v "$cmd" >/dev/null; then
    echo "ERROR: missing host tool '$cmd' (Android MPV source build)." >&2
    echo "  Debian/Ubuntu: sudo apt-get install -y gperf meson ninja-build nasm pkg-config cmake wget" >&2
    exit 1
  fi
done
command -v meson >/dev/null || echo "WARN: meson not in PATH" >&2
command -v ninja >/dev/null || echo "WARN: ninja not in PATH" >&2

FFMPEG_COMMIT="$(kotv_resolve_git_ref "$FFMPEG_REPO" "$FFMPEG_REF" "${KOTV_FFMPEG_COMMIT:-}")"
MPV_COMMIT="$(kotv_resolve_git_ref "$MPV_REPO" "$MPV_REF" "${KOTV_MPV_COMMIT:-}")"
MPV_ANDROID_COMMIT="$(kotv_resolve_git_ref "$MPV_ANDROID_REPO" "$MPV_ANDROID_REF" "${KOTV_MPV_ANDROID_COMMIT:-}")"
LIBPLACEBO_COMMIT="$(kotv_resolve_git_ref "$LIBPLACEBO_REPO" "$LIBPLACEBO_REF" "${KOTV_LIBPLACEBO_COMMIT:-}")"
echo "ok android pins: ffmpeg=${FFMPEG_COMMIT:0:12} mpv=${MPV_COMMIT:0:12} builder=${MPV_ANDROID_COMMIT:0:12} libplacebo=${LIBPLACEBO_COMMIT:0:12}"

want="fongmi-android=${MPV_ANDROID_COMMIT:0:12} ffmpeg=${FFMPEG_COMMIT:0:12} mpv=${MPV_COMMIT:0:12} libplacebo=${LIBPLACEBO_COMMIT:0:12}"
jni="$ROOT/flutter/android/app/src/main/jniLibs"
has_suite() {
  local abi="$1" dir="$2"
  [[ -s "$dir/$abi/libmpv.so" && -s "$dir/$abi/libplayer.so" && -s "$dir/$abi/libffmpeg.so" && -s "$dir/$abi/libc++_shared.so" ]]
}
if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$want" ]] && has_suite arm64-v8a "$ASSET" && has_suite armeabi-v7a "$ASSET"; then
  echo "ok cached Android MPV source build ($want)"
  exit 0
fi
if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$want" ]] && has_suite arm64-v8a "$jni" && has_suite armeabi-v7a "$jni"; then
  echo "ok cached Android MPV already in jniLibs ($want)"
  exit 0
fi

SRC="$WORK/mpv-android"
echo "==> clone FongMi/mpv-android ${MPV_ANDROID_COMMIT:0:12}"
mkdir -p "$WORK"
if [[ ! -d "$SRC/.git" ]]; then
  git clone --filter=blob:none --depth 1 "$MPV_ANDROID_REPO" "$SRC"
fi
git -C "$SRC" fetch --depth 1 origin "$MPV_ANDROID_COMMIT"
git -C "$SRC" checkout -q "$MPV_ANDROID_COMMIT" 2>/dev/null \
  || git -C "$SRC" checkout -q FETCH_HEAD
[[ "$(git -C "$SRC" rev-parse HEAD)" == "$MPV_ANDROID_COMMIT" ]] \
  || { echo "ERROR: mpv-android HEAD != $MPV_ANDROID_COMMIT" >&2; exit 1; }

BS="$SRC/buildscripts"
mkdir -p "$BS/deps"
# 预置 mpv 到 tip commit（ci.sh 见已有 deps/mpv 则跳过 clone）。
if [[ ! -d "$BS/deps/mpv/.git" ]]; then
  git clone --filter=blob:none --depth 1 "$MPV_REPO" "$BS/deps/mpv"
fi
git -C "$BS/deps/mpv" fetch --depth 1 origin "$MPV_COMMIT"
git -C "$BS/deps/mpv" checkout -q "$MPV_COMMIT" 2>/dev/null \
  || git -C "$BS/deps/mpv" checkout -q FETCH_HEAD
[[ "$(git -C "$BS/deps/mpv" rev-parse HEAD)" == "$MPV_COMMIT" ]] \
  || { echo "ERROR: mpv HEAD != $MPV_COMMIT" >&2; exit 1; }

# FongMi path.sh 写死 ANDROID_HOME=$DIR/sdk/android-sdk-$os；尽量链到已有 SDK。
if [[ -z "${ANDROID_HOME:-}" ]]; then
  if [[ -n "${ANDROID_SDK_ROOT:-}" && -d "$ANDROID_SDK_ROOT" ]]; then
    export ANDROID_HOME="$ANDROID_SDK_ROOT"
  elif [[ -d "$HOME/Android/Sdk" ]]; then
    export ANDROID_HOME="$HOME/Android/Sdk"
  elif [[ -d "$HOME/Library/Android/sdk" ]]; then
    export ANDROID_HOME="$HOME/Library/Android/sdk"
  fi
fi

export IN_CI=1
export FFMPEG_GIT_URL="$FFMPEG_REPO"
export FFMPEG_GIT_COMMIT="$FFMPEG_COMMIT"
export LIBPLACEBO_GIT_URL="$LIBPLACEBO_REPO"
export LIBPLACEBO_GIT_COMMIT="$LIBPLACEBO_COMMIT"
export MPV_GIT_URL="$MPV_REPO"
export MPV_GIT_REF="$MPV_REF"
export MPV_ANDROID_ARCHES="$ARCHES"
export MPV_ANDROID_NATIVE_ONLY=1
export WGET="${WGET:-wget --progress=dot:giga}"
# 宿主 jobs：buildall 读 cores；path.sh 默认 nproc。
export cores="${KOTV_MPV_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

echo "==> FongMi ci.sh install (SDK/NDK + deps + prefix)"
(
  cd "$BS"
  # install 会链 ANDROID_HOME、下 NDK r30、编 base prefix + libplacebo
  ./include/ci.sh install
)

echo "==> FongMi ci.sh build (mpv + ndk-build libplayer, native-only)"
(
  cd "$BS"
  ./include/ci.sh build
)

copy_abi() {
  local abi="$1"
  local src="$SRC/app/src/main/libs/$abi"
  local dest="$ASSET/$abi"
  mkdir -p "$dest"
  [[ -d "$src" ]] || { echo "ERROR: missing FongMi libs dir $src" >&2; exit 1; }
  # 清掉旧 webhtv 拆库残留，避免 staging 混装。
  rm -f "$dest"/libmv*.so "$dest"/libmw*.so
  local lib
  for lib in libc++_shared.so libffmpeg.so libmpv.so libplayer.so; do
    [[ -s "$src/$lib" ]] || { echo "ERROR: missing $src/$lib" >&2; exit 1; }
    cp -f "$src/$lib" "$dest/$lib"
  done
  # FongMi verify-package 已跑过；这里再做 KOTV 业务校验。
  if ! grep -aq 'libcurl' "$dest/libmpv.so"; then
    echo "ERROR: $abi/libmpv.so built without libcurl" >&2
    exit 1
  fi
  if ! grep -aqE 'vulkan|androidvk' "$dest/libmpv.so"; then
    echo "ERROR: $abi/libmpv.so lacks vulkan" >&2
    exit 1
  fi
  if ! grep -aqE 'libarcdav3a|AV3A Audio Vivid|--enable-libarcdav3a' "$dest/libffmpeg.so"; then
    echo "ERROR: $abi/libffmpeg.so lacks AV3A" >&2
    exit 1
  fi
  if ! grep -aqE 'av_dovi_rpu_parser_|dovi_rpu' "$dest/libffmpeg.so"; then
    echo "ERROR: $abi/libffmpeg.so lacks Dolby Vision RPU parser" >&2
    exit 1
  fi
  if ! grep -aq 'dvdnav' "$dest/libmpv.so" || ! grep -aq 'libbluray' "$dest/libmpv.so"; then
    echo "ERROR: $abi/libmpv.so lacks DVD/Blu-ray ISO (dvdnav + libbluray)" >&2
    exit 1
  fi
  echo "ok $abi source libmpv $(wc -c <"$dest/libmpv.so" | tr -d ' ') bytes (ffmpeg=$(wc -c <"$dest/libffmpeg.so" | tr -d ' '))"
}

copy_abi arm64-v8a
copy_abi armeabi-v7a
printf '%s\n' "$want" >"$STAMP"
echo "==> Android MPV source build staged at $ASSET ($want)"
