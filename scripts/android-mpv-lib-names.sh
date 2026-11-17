#!/usr/bin/env bash
# Android 自研 MPV 套件名称（供 prepare / verify / CI cache key 共用）。
# 套件进 jniLibs（System.loadLibrary）；assets/mpv-libs 仅保留 libvulkan stub。
# FongMi/mpv-android：合并 FFmpeg → libffmpeg.so（不再用 webhtv 的 mv*/mw* 拆库）。
# shellcheck disable=SC2034

# libmpv 依赖的 libc++ 符号；ass-kt 等旧 libc++ 会缺。
KOTV_ANDROID_LIBCXX_REQUIRED_SYM='_ZNSt6__ndk127__from_chars_floating_pointIfE'

# jniLibs 必须具备的自研套件（与 MPVLib LOAD_ORDER / prepare sync 一致）。
KOTV_ANDROID_MPV_JNI_REQUIRED=(
  libc++_shared.so
  libffmpeg.so
  libmpv.so
  libplayer.so
  libkotv_dl.so
)

# merge 后用 jniLibs 再盖一次，避免 ass/nextlib 旧 libc++ 抢先。
KOTV_ANDROID_MPV_MERGE_OVERLAY=(
  libc++_shared.so
)

# assets/mpv-libs 不得再留套件（与 lib/ 重复打包）。
KOTV_ANDROID_MPV_ASSET_FORBIDDEN=(
  libmpv.so
  libplayer.so
  libffmpeg.so
  libc++_shared.so
  libkotv_dl.so
)

# 最终 APK lib/<abi>/ 必须有。
KOTV_ANDROID_MPV_APK_REQUIRED=(
  libmpv.so
  libplayer.so
  libffmpeg.so
  libkotv_dl.so
  libc++_shared.so
)

# 旧 webhtv 拆库名：sync 时删除，避免与 libffmpeg 混装。
KOTV_ANDROID_MPV_LEGACY_SPLIT=(
  libmvutil.so
  libmwresample.so
  libmwscale.so
  libmvcodec.so
  libmvformat.so
  libmvfilter.so
  libmvdevice.so
)

# 安卓 APK 禁止的 FVP/mdk 产物（FVP 插件已从 settings 剔除）。
# 注意：自研套件的 libffmpeg.so 是 FongMi 合并核，不在此列。
KOTV_ANDROID_FVP_APK_FORBIDDEN=(
  libfvp.so
  libmdk.so
  libdav1d.so
)

kotv_android_nm_bin() {
  if command -v llvm-nm >/dev/null 2>&1; then
    echo llvm-nm
  elif command -v nm >/dev/null 2>&1; then
    echo nm
  else
    echo ""
  fi
}

# 若有 nm，检查 .so 是否导出给定符号子串。
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
  kotv_android_so_has_sym "${1:-}" "$KOTV_ANDROID_LIBCXX_REQUIRED_SYM"
}
