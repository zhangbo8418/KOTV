#!/usr/bin/env bash
# 安卓自研 MPV 套件：库名与校验/同步辅助（prepare / build / verify / CI cache 共用）。
# 布局：套件进 jniLibs（System.loadLibrary）；assets/mpv-libs 仅留 libvulkan stub。
# shellcheck disable=SC2034

KOTV_ANDROID_MPV_ABIS=(arm64-v8a armeabi-v7a)

# 构建产物（不含 kotv_dl；kotv_dl 由 build-android-kotv-dl.sh 另编）。
# 与 MPVLib LOAD_ORDER 中 ffmpeg/mpv/player + c++_shared 对应。
KOTV_ANDROID_MPV_SUITE=(
  libc++_shared.so
  libffmpeg.so
  libmpv.so
  libplayer.so
)

# jniLibs / APK lib/<abi>/ 必须具备；assets 中不得再留（避免双份打包）。
KOTV_ANDROID_MPV_JNI_REQUIRED=(
  "${KOTV_ANDROID_MPV_SUITE[@]}"
  libkotv_dl.so
)

# 历史拆库名（缓存迁移时删掉，避免与 libffmpeg.so 混装）。
KOTV_ANDROID_MPV_LEGACY_PURGE=(
  libmvutil.so
  libmwresample.so
  libmwscale.so
  libmvcodec.so
  libmvformat.so
  libmvfilter.so
  libmvdevice.so
)

# APK 禁止的 FVP/mdk 产物（插件已从 settings 剔除）。自研 libffmpeg.so 不在此列。
# Gradle packaging 排除见 flutter/android/kotv_android_no_fvp.gradle（须与此保持一致）。
KOTV_ANDROID_FVP_APK_FORBIDDEN=(
  libfvp.so
  libmdk.so
  libdav1d.so
)

# libmpv 依赖的 libc++ 符号；ass-kt 等旧 libc++ 会缺。
KOTV_ANDROID_LIBCXX_REQUIRED_SYM='_ZNSt6__ndk127__from_chars_floating_pointIfE'

kotv_android_nm_bin() {
  if command -v llvm-nm >/dev/null 2>&1; then
    echo llvm-nm
  elif command -v nm >/dev/null 2>&1; then
    echo nm
  else
    echo ""
  fi
}

kotv_android_so_has_sym() {
  local so="${1:-}"
  local sym="${2:-}"
  local nm_bin
  [[ -n "$so" && -f "$so" && -n "$sym" ]] || return 1
  nm_bin="$(kotv_android_nm_bin)"
  [[ -n "$nm_bin" ]] || return 0
  "$nm_bin" -D "$so" 2>/dev/null | grep -F "$sym" >/dev/null
}

kotv_android_libcxx_has_from_chars() {
  local so="${1:-}" nm_bin
  [[ -n "$so" && -f "$so" ]] || return 1
  nm_bin="$(kotv_android_nm_bin)"
  if [[ -n "$nm_bin" ]]; then
    "$nm_bin" -D "$so" 2>/dev/null | grep -F "$KOTV_ANDROID_LIBCXX_REQUIRED_SYM" >/dev/null
    return $?
  fi
  # 无 nm 时用字符串兜底（mangled 名含 from_chars_floating）。
  grep -a -q 'from_chars_floating' "$so" 2>/dev/null
}

# 核对 MPVLib.java 具备 libplayer create() 所需的静态回调（防签名漂移）。
kotv_android_mpv_check_jni_java_callbacks() {
  local java="${1:?}"
  local fail=0
  [[ -f "$java" ]] || {
    echo "ERROR: missing $java" >&2
    return 1
  }
  # JNI (JIJ)V → (long, int, long)
  if ! grep -qE 'void[[:space:]]+eventCommandReply[[:space:]]*\([[:space:]]*long[[:space:]]+[^,]+,[[:space:]]*int[[:space:]]+[^,]+,[[:space:]]*long[[:space:]]+' "$java"; then
    echo "ERROR: $java missing eventCommandReply(long,int,long) for libplayer JNI (JIJ)V" >&2
    fail=1
  fi
  if ! grep -qE 'void[[:space:]]+eventEndFile[[:space:]]*\([[:space:]]*int[[:space:]]+' "$java"; then
    echo "ERROR: $java missing eventEndFile(int,int,String) for libplayer JNI" >&2
    fail=1
  fi
  if ! grep -qE 'void[[:space:]]+logMessage[[:space:]]*\(' "$java"; then
    echo "ERROR: $java missing logMessage(...)" >&2
    fail=1
  fi
  # stream.cpp：FindClass("is/xyz/mpv/MPVLib$Stream") + openStream
  if ! grep -qE 'interface[[:space:]]+Stream[[:space:]]*\{' "$java"; then
    echo "ERROR: $java missing MPVLib.Stream for libplayer JNI" >&2
    fail=1
  fi
  if ! grep -qE 'Stream[[:space:]]+openStream[[:space:]]*\(' "$java"; then
    echo "ERROR: $java missing openStream(...) for libplayer JNI" >&2
    fail=1
  fi
  [[ "$fail" == 0 ]]
}

# $1=父目录（assets 或 jniLibs），$2=abi
kotv_android_mpv_has_suite() {
  local parent="${1:?}" abi="${2:?}" lib
  for lib in "${KOTV_ANDROID_MPV_SUITE[@]}"; do
    [[ -s "$parent/$abi/$lib" ]] || return 1
  done
  return 0
}

kotv_android_mpv_purge_legacy() {
  local dir="${1:?}" lib
  [[ -d "$dir" ]] || return 0
  for lib in "${KOTV_ANDROID_MPV_LEGACY_PURGE[@]}"; do
    rm -f "$dir/$lib"
  done
}

# $1=源目录 $2=目标目录；$3=1 时缺文件报错（默认 1），0 时跳过缺失
kotv_android_mpv_copy_suite() {
  local src="${1:?}" dest="${2:?}" require="${3:-1}" lib
  mkdir -p "$dest"
  for lib in "${KOTV_ANDROID_MPV_SUITE[@]}"; do
    if [[ -s "$src/$lib" ]]; then
      cp -f "$src/$lib" "$dest/$lib"
    elif [[ "$require" == 1 ]]; then
      echo "ERROR: missing $src/$lib" >&2
      return 1
    fi
  done
}

# 业务标记：vulkan/curl/ISO @ libmpv；AV3A/DoVi @ libffmpeg。失败打印 ERROR 并 return 1。
kotv_android_mpv_check_markers() {
  local abi="${1:?}" mpv="${2:?}" ffmpeg="${3:?}"
  local fail=0
  if ! grep -aq 'libcurl' "$mpv" 2>/dev/null; then
    echo "ERROR: $abi/libmpv.so built without libcurl" >&2
    fail=1
  fi
  if ! grep -aqE 'vulkan|androidvk' "$mpv" 2>/dev/null; then
    echo "ERROR: $abi/libmpv.so lacks vulkan" >&2
    fail=1
  fi
  if ! grep -aq 'dvdnav' "$mpv" 2>/dev/null || ! grep -aq 'libbluray' "$mpv" 2>/dev/null; then
    echo "ERROR: $abi/libmpv.so lacks DVD/Blu-ray ISO (dvdnav + libbluray)" >&2
    fail=1
  fi
  if ! grep -aqE 'libarcdav3a|AV3A Audio Vivid|--enable-libarcdav3a' "$ffmpeg" 2>/dev/null; then
    echo "ERROR: $abi/libffmpeg.so lacks AV3A" >&2
    fail=1
  fi
  if ! grep -aqE 'av_dovi_rpu_parser_|dovi_rpu' "$ffmpeg" 2>/dev/null; then
    echo "ERROR: $abi/libffmpeg.so lacks Dolby Vision RPU parser" >&2
    fail=1
  fi
  [[ "$fail" == 0 ]]
}
