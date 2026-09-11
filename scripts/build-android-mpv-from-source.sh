#!/usr/bin/env bash
# 安卓 libmpv / FFmpeg 从源码编进 assets/mpv-libs，不再下载 webhtv 预编译包。
#
# 现有预编译已经开了这些功能（libmpv 里的 enabled features）：
#   aaudio android android-media-ndk audiotrack egl-android ffmpeg gl
#   iconv libarchive libass libavdevice libbluray dvdnav libcurl libplacebo lua
#   opensles rubberband uchardet vulkan
# 以及 curl 8.21.0（nghttp2，HTTP/2；二进制里有 HTTP/3 相关路径）。
# PC 自编多出来、这份也要有的：同一 FongMi mpv 提交、libcurl、Vulkan、lua、
# FFmpeg 网络（http/https/rtsp/rtmp）+ AV3A。libavdevice 安卓预编译是开的，保留。
# 另外打上 mpegts 图片壳探测，对齐 Exo，不再用 Go 代理剥切片。
#
# 构建器与锁定版本来自 webhtv（与现网 .so 同一套功能）。
# CI 自己编 FFmpeg、libmpv 和 libplayer JNI，不下载预编译包，也不提交 .so。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIN="${KOTV_WEBHTV_MPV_PIN:-784b90420d646eb6c7ddcc63ad622a92c65b02b4}"
WORK="${KOTV_ANDROID_MPV_SRC:-$ROOT/.build/android-mpv-src}"
ASSET="$ROOT/flutter/android/app/src/main/assets/mpv-libs"
STAMP="$ASSET/.kotv-source-build"
PATCH="$ROOT/scripts/ffmpeg-mpegts-skip-image-prefix.py"
JOBS="${KOTV_MPV_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

need() { command -v "$1" >/dev/null || { echo "need $1" >&2; exit 1; }; }
for cmd in git curl python3 pkg-config perl cmake gperf make; do
  need "$cmd"
done

patch_hash="$(python3 - "$PATCH" <<'PY'
import hashlib, pathlib, sys
print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest()[:16])
PY
)"
want="webhtv=${PIN} patch=${patch_hash}"
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

echo "==> clone webhtv $PIN (build scripts + patches only used as the Android native builder)"
mkdir -p "$WORK"
if [[ ! -d "$WORK/webhtv/.git" ]]; then
  git clone --filter=blob:none --depth 1 https://github.com/fish2018/webhtv.git "$WORK/webhtv"
fi
git -C "$WORK/webhtv" fetch --depth 1 origin "$PIN"
git -C "$WORK/webhtv" checkout -q "$PIN"

cp -f "$PATCH" "$WORK/webhtv/third_party/patches/ffmpeg-mpegts-skip-image-prefix.py"
build_sh="$WORK/webhtv/scripts/build_mpv_native.sh"
if ! grep -q 'ffmpeg-mpegts-skip-image-prefix.py' "$build_sh"; then
  python3 - "$build_sh" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
text = p.read_text(encoding="utf-8")
needle = 'git -C "$deps/ffmpeg" apply "$FFMPEG_AUDIO_MEDIACODEC_HARDWARE_PATCH"\n'
insert = needle + '  python3 "$ROOT/third_party/patches/ffmpeg-mpegts-skip-image-prefix.py" "$deps/ffmpeg"\n'
if needle not in text:
    raise SystemExit("webhtv ffmpeg patch hook not found")
p.write_text(text.replace(needle, insert, 1), encoding="utf-8")
print("ok hooked mpegts probe patch into webhtv build script")
PY
fi
chmod +x "$build_sh" "$PATCH"

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
