#!/usr/bin/env bash
# 安卓 libmpv / FFmpeg / libplayer JNI 从源码编。
# 构建树：mpv-android（默认分支 fongmi）；产物为 libffmpeg.so + libmpv.so + libplayer.so。
# 默认 tip：FFmpeg=release-9.1-fongmi，mpv / mpv-android / libplacebo=fongmi；
# KOTV_*_COMMIT 可覆盖做可复现构建。不下载、不提交预编译 .so。
#
# 能力：opengl/vulkan/shaderc/libass/libcurl/libbluray/dvdnav/libarchive/rubberband
#   + FFmpeg AV3A(libarcdav3a) + DoVi RPU（在 libffmpeg.so 内）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/kotv-win-build-env.sh
source "$ROOT/scripts/kotv-win-build-env.sh"
# shellcheck source=scripts/kotv-resolve-git-ref.sh
source "$ROOT/scripts/kotv-resolve-git-ref.sh"
# shellcheck source=scripts/android-mpv-lib-names.sh
source "$ROOT/scripts/android-mpv-lib-names.sh"

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
JNI="$ROOT/flutter/android/app/src/main/jniLibs"
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

want="builder=${MPV_ANDROID_COMMIT:0:12} ffmpeg=${FFMPEG_COMMIT:0:12} mpv=${MPV_COMMIT:0:12} libplacebo=${LIBPLACEBO_COMMIT:0:12}"
if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$want" ]] \
  && kotv_android_mpv_has_suite "$ASSET" arm64-v8a \
  && kotv_android_mpv_has_suite "$ASSET" armeabi-v7a; then
  echo "ok cached Android MPV source build ($want)"
  exit 0
fi
if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$want" ]] \
  && kotv_android_mpv_has_suite "$JNI" arm64-v8a \
  && kotv_android_mpv_has_suite "$JNI" armeabi-v7a; then
  echo "ok cached Android MPV already in jniLibs ($want)"
  exit 0
fi

SRC="$WORK/mpv-android"
echo "==> clone mpv-android ${MPV_ANDROID_COMMIT:0:12}"
mkdir -p "$WORK"
kotv_git_checkout_commit "$SRC" "$MPV_ANDROID_REPO" "$MPV_ANDROID_COMMIT"
[[ "$(git -C "$SRC" rev-parse HEAD)" == "$MPV_ANDROID_COMMIT" ]] \
  || { echo "ERROR: mpv-android HEAD != $MPV_ANDROID_COMMIT" >&2; exit 1; }

BS="$SRC/buildscripts"
mkdir -p "$BS/deps"
# 预置 mpv tip（ci.sh 见已有 deps/mpv 则跳过 clone）。
kotv_git_checkout_commit "$BS/deps/mpv" "$MPV_REPO" "$MPV_COMMIT"
[[ "$(git -C "$BS/deps/mpv" rev-parse HEAD)" == "$MPV_COMMIT" ]] \
  || { echo "ERROR: mpv HEAD != $MPV_COMMIT" >&2; exit 1; }

# CMake 4 起拒绝 cmake_minimum_required < 3.5（uavs3d 仍写 3.1）。
# 给 android_cmake_setup 统一加 POLICY_VERSION_MINIMUM，避免各依赖分别打补丁。
python3 - "$BS/include/cmake-android.sh" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
needle = '-DCMAKE_POSITION_INDEPENDENT_CODE=ON \\\n'
flag = '-DCMAKE_POLICY_VERSION_MINIMUM=3.5 \\\n\t\t'
if "CMAKE_POLICY_VERSION_MINIMUM" in text:
    print("ok cmake-android already sets CMAKE_POLICY_VERSION_MINIMUM")
elif needle not in text:
    raise SystemExit("ERROR: cmake-android.sh PIC flag line changed; update KOTV patch")
else:
    path.write_text(text.replace(needle, needle + flag, 1), encoding="utf-8")
    print("ok patched cmake-android.sh for CMAKE_POLICY_VERSION_MINIMUM=3.5")
PY

# mpv-android path.sh 把 ANDROID_HOME 指到 buildscripts/sdk/…；尽量链已有 SDK。
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
export cores="${KOTV_MPV_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

echo "==> mpv-android ci.sh install (SDK/NDK + deps + prefix)"
( cd "$BS" && ./include/ci.sh install )

echo "==> mpv-android ci.sh build (mpv + ndk-build libplayer, native-only)"
( cd "$BS" && ./include/ci.sh build )

stage_abi() {
  local abi="$1"
  local src="$SRC/app/src/main/libs/$abi"
  local dest="$ASSET/$abi"
  [[ -d "$src" ]] || { echo "ERROR: missing builder libs $src" >&2; exit 1; }
  mkdir -p "$dest"
  kotv_android_mpv_purge_legacy "$dest"
  kotv_android_mpv_copy_suite "$src" "$dest" 1
  kotv_android_mpv_check_markers "$abi" "$dest/libmpv.so" "$dest/libffmpeg.so" \
    || exit 1
  echo "ok $abi staged libmpv=$(wc -c <"$dest/libmpv.so" | tr -d ' ') libffmpeg=$(wc -c <"$dest/libffmpeg.so" | tr -d ' ')"
}

for abi in "${KOTV_ANDROID_MPV_ABIS[@]}"; do
  stage_abi "$abi"
done
printf '%s\n' "$want" >"$STAMP"
echo "==> Android MPV source build staged at $ASSET ($want)"
