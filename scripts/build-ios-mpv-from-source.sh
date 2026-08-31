#!/usr/bin/env bash
# 构建 iOS arm64 libmpv（FongMi mpv + AV3A FFmpeg），写入 flutter/assets/mpv-libs/ios/。
# 需要：macOS + Xcode + meson/ninja/pkg-config/cmake/nasm。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSET="$ROOT/flutter/assets/mpv-libs/ios"
BUILD_DIR="${KOTV_IOS_MPV_BUILD_DIR:-$ROOT/.build/ios-mpv}"
PREFIX="$BUILD_DIR/prefix"
JOBS="${KOTV_MPV_JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
MPV_REPO="${KOTV_MPV_REPO:-https://github.com/FongMi/mpv.git}"
MPV_COMMIT="${KOTV_MPV_COMMIT:-cca559b41ceb0bb7731cf6ef2e1f33276cd30c42}"
FFMPEG_REPO="${KOTV_FFMPEG_REPO:-https://github.com/FongMi/FFmpeg.git}"
FFMPEG_COMMIT="${KOTV_FFMPEG_COMMIT:-04482c8d13ac27b2a9fe93f5d388929eef8af5f4}"
MIN_IOS="${KOTV_IOS_MIN:-12.0}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "ERROR: iOS libmpv 只能在 macOS + Xcode 上构建" >&2
  exit 1
fi

need() { command -v "$1" >/dev/null || { echo "need $1" >&2; exit 1; }; }
need git
need cmake
need meson
need ninja
need pkg-config
need xcrun

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CC="$(xcrun --sdk iphoneos -f clang)"
CXX="$(xcrun --sdk iphoneos -f clang++)"
AR="$(xcrun --sdk iphoneos -f ar)"
RANLIB="$(xcrun --sdk iphoneos -f ranlib)"
export CC CXX AR RANLIB
export CFLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=$MIN_IOS -fPIC -O2"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=$MIN_IOS"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

mkdir -p "$ASSET" "$BUILD_DIR" "$PREFIX/lib/pkgconfig"
cd "$BUILD_DIR"

STAMP="$PREFIX/.kotv-ios-mpv-av3a-v1"
OUT="$ASSET/libmpv.dylib"
if [[ -f "$STAMP" && -f "$OUT" && "$(wc -c <"$OUT" | tr -d ' ')" -ge 500000 ]]; then
  if grep -aqE 'libarcdav3a|AV3A Audio Vivid' "$OUT" 2>/dev/null; then
    echo "ok cached ios/libmpv.dylib"
    exit 0
  fi
fi

echo "==> iOS FFmpeg+AV3A+libmpv → $OUT"
echo "    SDK=$SDK"

if [[ ! -d ffmpeg/.git ]]; then
  git clone --filter=blob:none --depth 1 "$FFMPEG_REPO" ffmpeg
  git -C ffmpeg fetch --depth 1 origin "$FFMPEG_COMMIT"
  git -C ffmpeg checkout -q "$FFMPEG_COMMIT"
else
  git -C ffmpeg fetch --depth 1 origin "$FFMPEG_COMMIT" 2>/dev/null || true
  git -C ffmpeg checkout -q "$FFMPEG_COMMIT"
fi

[[ -f ffmpeg/dependency/avs3a/CMakeLists.txt ]] \
  || { echo "ERROR: missing ffmpeg/dependency/avs3a" >&2; exit 1; }

echo "==> cmake arcdav3a (ios arm64 static PIC)"
rm -rf arcdav3a-build
cmake -G "Unix Makefiles" -S ffmpeg/dependency/avs3a -B arcdav3a-build \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_IOS" \
  -DCMAKE_OSX_SYSROOT="$SDK" \
  -DCMAKE_C_FLAGS="$CFLAGS" \
  -DCMAKE_CXX_FLAGS="$CXXFLAGS"
cmake --build arcdav3a-build -j"$JOBS"
cmake --install arcdav3a-build
[[ -f "$PREFIX/lib/libarcdav3a.a" ]] || { echo "ERROR: missing libarcdav3a.a" >&2; exit 1; }

cat >"$PREFIX/lib/pkgconfig/arcdav3a.pc" <<EOF
prefix=$PREFIX
exec_prefix=$PREFIX
libdir=$PREFIX/lib
includedir=$PREFIX/include

Name: arcdav3a
Description: AVS3-P3 / AV3A decoder (libarcdav3a)
Version: 1.0.0
Libs: -L$PREFIX/lib -larcdav3a -lm
Cflags: -I$PREFIX/include
EOF

echo "==> configure FongMi FFmpeg (ios arm64 static + libarcdav3a)"
cd ffmpeg
make distclean 2>/dev/null || true
./configure \
  --prefix="$PREFIX" \
  --enable-static --disable-shared \
  --disable-programs --disable-doc --disable-debug \
  --enable-pic \
  --enable-libarcdav3a \
  --extra-cflags="-I$PREFIX/include" \
  --extra-ldflags="-L$PREFIX/lib" \
  --extra-libs="-larcdav3a -lm" \
  --arch=arm64 \
  --target-os=darwin \
  --enable-cross-compile \
  --cc="$CC" \
  --cxx="$CXX" \
  --ar="$AR" \
  --ranlib="$RANLIB" \
  --sysroot="$SDK" \
  --disable-videotoolbox \
  --disable-audiotoolbox \
  --disable-metal \
  --disable-appkit \
  --disable-coreimage \
  --disable-avfoundation
make -j"$JOBS"
make install
cd "$BUILD_DIR"

# 把 -larcdav3a 提到 Libs，便于 meson 动态链接探测
if [[ -f "$PREFIX/lib/pkgconfig/libavcodec.pc" ]]; then
  if ! grep -E '^Libs:' "$PREFIX/lib/pkgconfig/libavcodec.pc" | grep -q -- '-larcdav3a'; then
    python3 - "$PREFIX/lib/pkgconfig/libavcodec.pc" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
lines = p.read_text().splitlines(True)
out = []
for line in lines:
    if line.startswith("Libs:") and "-larcdav3a" not in line:
        nl = "\n" if line.endswith("\n") else ""
        line = line.rstrip("\r\n") + " -larcdav3a -lm" + nl
    out.append(line)
p.write_text("".join(out))
PY
  fi
fi

if [[ ! -d mpv/.git ]]; then
  git clone --filter=blob:none --depth 1 "$MPV_REPO" mpv
  git -C mpv fetch --depth 1 origin "$MPV_COMMIT"
  git -C mpv checkout -q "$MPV_COMMIT"
else
  git -C mpv fetch --depth 1 origin "$MPV_COMMIT" 2>/dev/null || true
  git -C mpv checkout -q "$MPV_COMMIT"
fi

cat >"$BUILD_DIR/ios-cross.ini" <<EOF
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$AR'
strip = '$(xcrun --sdk iphoneos -f strip)'
pkg-config = 'pkg-config'

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'

[built-in options]
c_args = ['-arch', 'arm64', '-isysroot', '$SDK', '-miphoneos-version-min=$MIN_IOS']
cpp_args = ['-arch', 'arm64', '-isysroot', '$SDK', '-miphoneos-version-min=$MIN_IOS']
c_link_args = ['-arch', 'arm64', '-isysroot', '$SDK', '-miphoneos-version-min=$MIN_IOS']
cpp_link_args = ['-arch', 'arm64', '-isysroot', '$SDK', '-miphoneos-version-min=$MIN_IOS']
EOF

cd mpv
rm -rf build
meson setup build \
  --cross-file "$BUILD_DIR/ios-cross.ini" \
  --prefix="$PREFIX" \
  -Ddefault_library=shared \
  -Dlibmpv=true \
  -Dcplayer=false \
  -Dmanpage-build=disabled \
  -Dvulkan=disabled \
  -Dlua=disabled \
  -Dswift-build=disabled \
  -Dmacos-cocoa-cb=disabled \
  -Dmacos-media-player=disabled \
  -Dmacos-touchbar=disabled
meson compile -C build -j"$JOBS"

DLL=""
for cand in build/libmpv.dylib build/libmpv.2.dylib; do
  [[ -f "$cand" ]] && DLL="$cand" && break
done
[[ -n "$DLL" ]] || DLL="$(find build -name 'libmpv*.dylib' | head -1 || true)"
[[ -n "$DLL" && -f "$DLL" ]] || { echo "ERROR: ios libmpv.dylib not found" >&2; exit 1; }

mkdir -p "$ASSET"
cp -f "$DLL" "$OUT"
if command -v install_name_tool >/dev/null; then
  install_name_tool -id "@rpath/libmpv.dylib" "$OUT" 2>/dev/null || true
fi
grep -aqE 'libarcdav3a|AV3A Audio Vivid' "$OUT" \
  || { echo "ERROR: ios libmpv.dylib missing AV3A symbols" >&2; exit 1; }
echo av3a-ios-v1 >"$STAMP"
echo "built $OUT ($(wc -c <"$OUT" | tr -d ' ') bytes)"
ls -lh "$OUT"
