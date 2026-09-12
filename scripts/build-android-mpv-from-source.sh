#!/usr/bin/env bash
# 安卓 libmpv / FFmpeg / libplayer JNI 从源码编。
# webhtv 只提供交叉编译脚本、补丁与 JNI 源码；FFmpeg 跟 FongMi release-9.0-fongmi tip（RELEASE=9.0.1）。
# CI 不下载预编译 .so，也不提交 .so。
#
# 现网功能：aaudio android android-media-ndk audiotrack egl-android ffmpeg gl
#   iconv libarchive libass libavdevice libbluray dvdnav libcurl libplacebo libdovi lua
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
want="webhtv=${WEBHTV_REF} ffmpeg=${FFMPEG_COMMIT:0:12} libdovi=1 lcms=1 xxhash=1"
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

# webhtv 对 mpv 浅克隆 + tag deepen 在 CI 上不稳：要么 shallow 文件冲突，要么 describe 对不上。
# 保留原 deepen 顺序并加重试；最终以 lock 的 MPV_VERSION 文件为准（webhtv 本就会写这个文件）。
python3 - "$build_sh" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
old = '''  if [ "$(git -C "$deps/mpv" describe --abbrev=9 --tags --match "$MPV_DESCRIBE_TAG" HEAD 2>/dev/null || true)" != "v$MPV_VERSION" ]; then
    # Fetch the upstream tag first. A depth-1 tag fetch marks the tag commit as
    # a shallow boundary; expanding the selected FongMi commit afterwards
    # reconnects that commit and keeps git-describe deterministic.
    git -C "$deps/mpv" fetch --depth=1 "$MPV_TAG_REPO" \\
      "refs/tags/$MPV_DESCRIBE_TAG:refs/tags/$MPV_DESCRIBE_TAG"
    git -C "$deps/mpv" fetch --depth="$MPV_HISTORY_DEPTH" origin "$MPV_COMMIT"
  fi
  [ "$(git -C "$deps/mpv" describe --abbrev=9 --tags --match "$MPV_DESCRIBE_TAG" HEAD)" = "v$MPV_VERSION" ] || die "MPV describe version mismatch"'''
new = '''  if [ "$(git -C "$deps/mpv" describe --abbrev=9 --tags --match "$MPV_DESCRIBE_TAG" HEAD 2>/dev/null || true)" != "v$MPV_VERSION" ]; then
    # Same deepen order as upstream webhtv, with retries for shallow-file races.
    _ok=0
    for _try in 1 2 3 4 5 6; do
      rm -f "$deps/mpv/.git/shallow.lock" || true
      if git -C "$deps/mpv" fetch --depth=1 "$MPV_TAG_REPO" \\
          "refs/tags/$MPV_DESCRIBE_TAG:refs/tags/$MPV_DESCRIBE_TAG" \\
        && git -C "$deps/mpv" fetch --depth="$MPV_HISTORY_DEPTH" origin "$MPV_COMMIT" \\
        && [ "$(git -C "$deps/mpv" describe --abbrev=9 --tags --match "$MPV_DESCRIBE_TAG" HEAD 2>/dev/null || true)" = "v$MPV_VERSION" ]; then
        _ok=1
        break
      fi
      sleep "$_try"
    done
    if [ "$_ok" != "1" ]; then
      log "MPV git-describe still mismatched after retries; embedding lock version $MPV_VERSION"
      git -C "$deps/mpv" fetch --unshallow origin 2>/dev/null || true
      git -C "$deps/mpv" fetch --no-tags "$MPV_TAG_REPO" \\
        "refs/tags/$MPV_DESCRIBE_TAG:refs/tags/$MPV_DESCRIBE_TAG" 2>/dev/null || true
    fi
  fi'''
if old not in text:
    raise SystemExit("ERROR: webhtv mpv shallow-fetch block changed; update KOTV patch")
path.write_text(text.replace(old, new, 1), encoding="utf-8")
print("ok patched webhtv mpv shallow fetch + soft describe")
PY

# 安卓 libplacebo 启用 libdovi（杜比视界）：复用 webhtv exo-dv5 预编译静态库。
OVERRIDES="$WORK/webhtv/third_party/mpv-native-overrides"
DOVI_NATIVE="$WORK/webhtv/third_party/exo-dv5-native"
[[ -d "$DOVI_NATIVE/prebuilt/arm64-v8a" ]] || { echo "ERROR: missing $DOVI_NATIVE prebuilt libdovi" >&2; exit 1; }

cat >"$OVERRIDES/libdovi.sh" <<'EOF'
#!/bin/bash -e
# Install webhtv exo-dv5 prebuilt libdovi into the ABI prefix for libplacebo.
. ../../include/path.sh

if [ "$1" == "build" ]; then
	true
elif [ "$1" == "clean" ]; then
	exit 0
else
	exit 255
fi

WEBHTV_ROOT="${WEBHTV_ROOT:-}"
if [ -z "$WEBHTV_ROOT" ]; then
	# deps/libdovi -> buildscripts -> mpv-android -> work -> webhtv (via env preferred)
	echo "ERROR: WEBHTV_ROOT unset (needed for exo-dv5-native libdovi)" >&2
	exit 1
fi

case "$prefix_name" in
	arm64) abi=arm64-v8a ;;
	armv7l) abi=armeabi-v7a ;;
	*)
		echo "ERROR: unsupported prefix_name=$prefix_name for libdovi" >&2
		exit 1
		;;
esac

src="$WEBHTV_ROOT/third_party/exo-dv5-native"
[ -f "$src/prebuilt/$abi/libdovi.a" ] || {
	echo "ERROR: missing $src/prebuilt/$abi/libdovi.a" >&2
	exit 1
}
[ -f "$src/include/libdovi/rpu_parser.h" ] || {
	echo "ERROR: missing $src/include/libdovi/rpu_parser.h" >&2
	exit 1
}

mkdir -p "$prefix_dir/lib" "$prefix_dir/include/libdovi" "$prefix_dir/lib/pkgconfig"
cp -f "$src/prebuilt/$abi/libdovi.a" "$prefix_dir/lib/libdovi.a"
cp -f "$src/include/libdovi/"*.h "$prefix_dir/include/libdovi/"
cat >"$prefix_dir/lib/pkgconfig/dovi.pc" <<PC
prefix=/usr/local
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: dovi
Description: Dolby Vision metadata library (libdovi)
Version: 3.3.0
Libs: -L\${libdir} -ldovi
Libs.private: -ldl -lm
Cflags: -I\${includedir}
PC

pkg-config --exists dovi || {
	echo "ERROR: dovi.pc not visible after install" >&2
	exit 1
}
echo "ok libdovi ($abi) -> $prefix_dir/lib/libdovi.a"
EOF
chmod +x "$OVERRIDES/libdovi.sh"

python3 - "$OVERRIDES/libplacebo.sh" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
old = """meson setup "$build" --cross-file "$prefix_dir/crossfile.txt" \\
	-Dopengl=enabled -Dvulkan=enabled \\
	-Dshaderc=enabled -Dglslang=disabled \\
	-Ddemos=false

config_header="$build/src/include/libplacebo/config.h"
for backend in OPENGL VULKAN; do
	grep -Eq "^#define PL_HAVE_${backend} 1([[:space:]]|$)" "$config_header" || {
		echo "libplacebo backend PL_HAVE_${backend}=1 is missing." >&2
		exit 1
	}
done"""
new = """if [ ! -f "$prefix_dir/lib/libdovi.a" ]; then
	echo "libdovi dependency is missing: $prefix_dir/lib/libdovi.a" >&2
	exit 1
fi
if [ ! -f "$prefix_dir/lib/liblcms2.a" ]; then
	echo "lcms2 dependency is missing: $prefix_dir/lib/liblcms2.a" >&2
	exit 1
fi
if [ ! -f "$prefix_dir/lib/libxxhash.a" ]; then
	echo "xxhash dependency is missing: $prefix_dir/lib/libxxhash.a" >&2
	exit 1
fi
meson setup "$build" --cross-file "$prefix_dir/crossfile.txt" \\
	-Dopengl=enabled -Dvulkan=enabled \\
	-Dshaderc=enabled -Dglslang=disabled \\
	-Ddovi=enabled -Dlibdovi=enabled \\
	-Dlcms=enabled -Dxxhash=enabled \\
	-Ddemos=false

config_header="$build/src/include/libplacebo/config.h"
for backend in OPENGL VULKAN LIBDOVI LCMS XXHASH; do
	grep -Eq "^#define PL_HAVE_${backend} 1([[:space:]]|$)" "$config_header" || {
		echo "libplacebo feature PL_HAVE_${backend}=1 is missing." >&2
		exit 1
	}
done"""
if old not in text:
    raise SystemExit("ERROR: webhtv libplacebo.sh meson block changed; update KOTV patch")
# Also pull -ldovi/-llcms2/-lxxhash into Libs for static link consumers.
text2 = text.replace(old, new, 1)
text2 = text2.replace(
    'for library in ("-lshaderc", "-lc++"):',
    'for library in ("-lshaderc", "-ldovi", "-llcms2", "-lxxhash", "-lc++"):',
    1,
)
# Idempotent if already patched once
if '("-lshaderc", "-ldovi", "-llcms2", "-lxxhash", "-lc++")' not in text2 and '("-lshaderc", "-ldovi", "-lc++")' in text2:
    text2 = text2.replace(
        'for library in ("-lshaderc", "-ldovi", "-lc++"):',
        'for library in ("-lshaderc", "-ldovi", "-llcms2", "-lxxhash", "-lc++"):',
        1,
    )
path.write_text(text2, encoding="utf-8")
print("ok patched webhtv libplacebo.sh for libdovi+lcms+xxhash")
PY

# lcms2 + xxhash 覆盖脚本（与 libdovi 一样装进 ABI prefix）
cat >"$OVERRIDES/lcms2.sh" <<'EOF'
#!/bin/bash -e
. ../../include/path.sh
build=_build$ndk_suffix
if [ "$1" == "build" ]; then
	true
elif [ "$1" == "clean" ]; then
	rm -rf "$build"
	exit 0
else
	exit 255
fi
unset CC CXX
meson setup "$build" --cross-file "$prefix_dir/crossfile.txt" \
	-Ddefault_library=static -Dutils=false -Dsamples=false \
	-Dfastfloat=false -Dthreaded=false -Djpeg=disabled -Dtiff=disabled
ninja -C "$build" -j"$cores"
DESTDIR="$prefix_dir" ninja -C "$build" install
[ -f "$prefix_dir/lib/liblcms2.a" ] || { echo "ERROR: liblcms2.a missing" >&2; exit 1; }
EOF
chmod +x "$OVERRIDES/lcms2.sh"

cat >"$OVERRIDES/xxhash.sh" <<'EOF'
#!/bin/bash -e
. ../../include/path.sh
. ../../include/depinfo.sh
build=_build$ndk_suffix
if [ "$1" == "build" ]; then
	true
elif [ "$1" == "clean" ]; then
	rm -rf "$build"
	exit 0
else
	exit 255
fi
# path.sh 会 unset ANDROID_NDK_ROOT；直接用 buildall 注入的 NDK clang。
rm -rf "$build"
cmake -S cmake_unofficial -B "$build" \
	-DCMAKE_SYSTEM_NAME=Android \
	-DCMAKE_C_COMPILER="$CC" \
	-DCMAKE_CXX_COMPILER="$CXX" \
	-DCMAKE_AR="$AR" \
	-DCMAKE_RANLIB="$RANLIB" \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_INSTALL_PREFIX="$prefix_dir" \
	-DCMAKE_INSTALL_LIBDIR=lib \
	-DBUILD_SHARED_LIBS=OFF \
	-DXXHASH_BUILD_XXHSUM=OFF
cmake --build "$build" -j"$cores"
cmake --install "$build"
mkdir -p "$prefix_dir/lib/pkgconfig"
if [ ! -f "$prefix_dir/lib/pkgconfig/libxxhash.pc" ]; then
	cat >"$prefix_dir/lib/pkgconfig/libxxhash.pc" <<'PC'
prefix=/usr/local
exec_prefix=${prefix}
libdir=${prefix}/lib
includedir=${prefix}/include
Name: xxhash
Description: extremely fast hash algorithm
Version: 0.8.3
Libs: -L${libdir} -lxxhash
Cflags: -I${includedir}
PC
fi
[ -f "$prefix_dir/lib/libxxhash.a" ] || { echo "ERROR: libxxhash.a missing" >&2; exit 1; }
EOF
chmod +x "$OVERRIDES/xxhash.sh"

python3 - "$OVERRIDES/depinfo.sh" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
if "dep_libdovi=" not in text:
    text = text.replace("dep_shaderc=()\n", "dep_shaderc=()\ndep_libdovi=()\n", 1)
if "dep_lcms2=" not in text:
    text = text.replace("dep_libdovi=()\n", "dep_libdovi=()\ndep_lcms2=()\ndep_xxhash=()\n", 1)
# libplacebo deps: shaderc + libdovi + lcms2 + xxhash
for old, new in (
    ("dep_libplacebo=(shaderc)", "dep_libplacebo=(shaderc libdovi lcms2 xxhash)"),
    ("dep_libplacebo=(shaderc libdovi)", "dep_libplacebo=(shaderc libdovi lcms2 xxhash)"),
):
    if old in text:
        text = text.replace(old, new, 1)
        break
else:
    if "dep_libplacebo=(shaderc libdovi lcms2 xxhash)" not in text:
        raise SystemExit("ERROR: unexpected dep_libplacebo in webhtv depinfo.sh")
path.write_text(text, encoding="utf-8")
print("ok patched webhtv depinfo.sh for libdovi+lcms+xxhash")
PY

python3 - "$build_sh" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

# prepare_framework: copy + chmod libdovi.sh（缩进与 upstream 一致）
old_cp = (
    '  cp "$OVERRIDE_DIR/libplacebo.sh" "$BUILDSCRIPTS/scripts/libplacebo.sh"\n'
    '  cp "$OVERRIDE_DIR/nghttp2.sh" "$BUILDSCRIPTS/scripts/nghttp2.sh"\n'
)
new_cp = (
    '  cp "$OVERRIDE_DIR/libplacebo.sh" "$BUILDSCRIPTS/scripts/libplacebo.sh"\n'
    '  cp "$OVERRIDE_DIR/libdovi.sh" "$BUILDSCRIPTS/scripts/libdovi.sh"\n'
    '  cp "$OVERRIDE_DIR/lcms2.sh" "$BUILDSCRIPTS/scripts/lcms2.sh"\n'
    '  cp "$OVERRIDE_DIR/xxhash.sh" "$BUILDSCRIPTS/scripts/xxhash.sh"\n'
    '  cp "$OVERRIDE_DIR/nghttp2.sh" "$BUILDSCRIPTS/scripts/nghttp2.sh"\n'
)
if old_cp not in text:
    raise SystemExit("ERROR: webhtv prepare_framework libplacebo copy block changed")
text = text.replace(old_cp, new_cp, 1)

old_chmod = (
    '  chmod +x "$BUILDSCRIPTS/scripts/libass.sh" "$BUILDSCRIPTS/scripts/lua.sh" \\\n'
    '    "$BUILDSCRIPTS/scripts/shaderc.sh" \\\n'
    '    "$BUILDSCRIPTS/scripts/libplacebo.sh" "$BUILDSCRIPTS/scripts/nghttp2.sh" \\\n'
    '    "$BUILDSCRIPTS/scripts/curl.sh" "$BUILDSCRIPTS/scripts/mpv.sh"\n'
)
new_chmod = (
    '  chmod +x "$BUILDSCRIPTS/scripts/libass.sh" "$BUILDSCRIPTS/scripts/lua.sh" \\\n'
    '    "$BUILDSCRIPTS/scripts/shaderc.sh" \\\n'
    '    "$BUILDSCRIPTS/scripts/libplacebo.sh" "$BUILDSCRIPTS/scripts/libdovi.sh" \\\n'
    '    "$BUILDSCRIPTS/scripts/lcms2.sh" "$BUILDSCRIPTS/scripts/xxhash.sh" \\\n'
    '    "$BUILDSCRIPTS/scripts/nghttp2.sh" \\\n'
    '    "$BUILDSCRIPTS/scripts/curl.sh" "$BUILDSCRIPTS/scripts/mpv.sh"\n'
)
if old_chmod not in text:
    raise SystemExit("ERROR: webhtv prepare_framework chmod block changed")
text = text.replace(old_chmod, new_chmod, 1)

# prepare_sources: stub deps/libdovi + fetch lcms2/xxhash
needle = '  checkout_repo libplacebo "$LIBPLACEBO_REPO" "$LIBPLACEBO_COMMIT" "$deps/libplacebo" "$LIBPLACEBO_SUBMODULES"'
if needle not in text:
    raise SystemExit("ERROR: webhtv libplacebo checkout line changed")
if 'extract_archive lcms2' not in text:
    text = text.replace(
        needle,
        '  mkdir -p "$deps/libdovi"\n'
        '  extract_archive lcms2 \\\n'
        '    "https://github.com/mm2/Little-CMS/releases/download/lcms2.16/lcms2-2.16.tar.gz" \\\n'
        '    "d873d34ad8b9b4cea010631f1a6228d2087475e4dc5e763eb81acc23d9d45a51" \\\n'
        '    "$deps/lcms2"\n'
        '  extract_archive xxhash \\\n'
        '    "https://github.com/Cyan4973/xxHash/archive/refs/tags/v0.8.3.tar.gz" \\\n'
        '    "aae608dfe8213dfd05d909a57718ef82f30722c392344583d3f39050c7f29a80" \\\n'
        '    "$deps/xxhash"\n'
        + needle,
        1,
    )

# targets: libdovi/lcms2/xxhash before libplacebo
old_t = "    shaderc libplacebo\n"
new_t = "    shaderc libdovi lcms2 xxhash libplacebo\n"
if old_t not in text:
    if "shaderc libdovi lcms2 xxhash libplacebo" not in text:
        # already partially patched to libdovi only
        old_t2 = "    shaderc libdovi libplacebo\n"
        if old_t2 in text:
            text = text.replace(old_t2, new_t, 1)
        else:
            raise SystemExit("ERROR: webhtv targets shaderc/libplacebo line changed")
else:
    text = text.replace(old_t, new_t, 1)

old_case = (
    '      shaderc) [ -f "$BUILDSCRIPTS/prefix/$prefix_name/lib/libshaderc.a" ] ;;\n'
    '      libplacebo) [ -f "$BUILDSCRIPTS/prefix/$prefix_name/lib/libplacebo.a" ] ;;\n'
)
new_case = (
    '      shaderc) [ -f "$BUILDSCRIPTS/prefix/$prefix_name/lib/libshaderc.a" ] ;;\n'
    '      libdovi) [ -f "$BUILDSCRIPTS/prefix/$prefix_name/lib/libdovi.a" ] ;;\n'
    '      lcms2) [ -f "$BUILDSCRIPTS/prefix/$prefix_name/lib/liblcms2.a" ] ;;\n'
    '      xxhash) [ -f "$BUILDSCRIPTS/prefix/$prefix_name/lib/libxxhash.a" ] ;;\n'
    '      libplacebo) [ -f "$BUILDSCRIPTS/prefix/$prefix_name/lib/libplacebo.a" ] ;;\n'
)
if old_case not in text:
    old_case2 = (
        '      shaderc) [ -f "$BUILDSCRIPTS/prefix/$prefix_name/lib/libshaderc.a" ] ;;\n'
        '      libdovi) [ -f "$BUILDSCRIPTS/prefix/$prefix_name/lib/libdovi.a" ] ;;\n'
        '      libplacebo) [ -f "$BUILDSCRIPTS/prefix/$prefix_name/lib/libplacebo.a" ] ;;\n'
    )
    if old_case2 in text:
        text = text.replace(old_case2, new_case, 1)
    else:
        raise SystemExit("ERROR: webhtv target case shaderc/libplacebo changed")
else:
    text = text.replace(old_case, new_case, 1)

# Export WEBHTV_ROOT for libdovi.sh when building ABIs
old_build = '  log "Building pinned MPV native stack for $abi"\n'
new_build = '  export WEBHTV_ROOT="$ROOT"\n  log "Building pinned MPV native stack for $abi"\n'
if old_build not in text:
    raise SystemExit("ERROR: webhtv build_abi log line changed")
text = text.replace(old_build, new_build, 1)

# verify_directory: require libdovi symbols in libmpv
old_ver = (
    '  grep -Fq "v$LIBPLACEBO_VERSION" <<<"$version_strings" || '
    'die "unexpected libplacebo version in $directory/libmpv.so"\n'
)
new_ver = (
    old_ver
    + '  grep -Eq "dovi_parse_unspec62_nalu|pl_hdr_metadata_from_dovi_rpu|dovi_rpu_get_header" '
    '<<<"$version_strings" || die "libdovi markers missing from $directory/libmpv.so"\n'
)
if old_ver not in text:
    raise SystemExit("ERROR: webhtv verify libplacebo version check changed")
if "libdovi markers missing" not in text:
    text = text.replace(old_ver, new_ver, 1)

path.write_text(text, encoding="utf-8")
print("ok patched webhtv build_mpv_native.sh for libdovi")
PY

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
  if ! grep -aqE 'dovi_parse_unspec62_nalu|pl_hdr_metadata_from_dovi_rpu|dovi_rpu_get_header' "$dest/libmpv.so"; then
    echo "ERROR: $abi/libmpv.so lacks libdovi (Dolby Vision via libplacebo)" >&2
    exit 1
  fi
  echo "ok $abi source libmpv $(wc -c <"$dest/libmpv.so" | tr -d ' ') bytes"
}

copy_abi arm64_v8a arm64-v8a
copy_abi armeabi_v7a armeabi-v7a
printf '%s\n' "$want" >"$STAMP"
echo "==> Android MPV source build staged at $ASSET"
