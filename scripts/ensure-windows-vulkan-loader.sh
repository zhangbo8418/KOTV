#!/usr/bin/env bash
# 为 Win7 桌面包构建/缓存 Vulkan Loader 1.2.x（vulkan-1.dll）。
# libplacebo 最低要 Vulkan 1.2 API；用 1.2 代 loader 比 SDK 1.4 更适配 Win7 末代驱动。
# 用法: ensure-windows-vulkan-loader.sh
# 输出: 设置 KOTV_WINDOWS_VULKAN_DLL 指向 vulkan-1.dll
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${KOTV_VULKAN_LOADER_TAG:-v1.2.198}"
OUT_DIR="${KOTV_VULKAN_LOADER_DIR:-$ROOT/.build/vulkan-loader-win7}"
DLL="$OUT_DIR/vulkan-1.dll"
STAMP="$OUT_DIR/.tag"
JOBS="${KOTV_MPV_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
SRC="$ROOT/.build/Vulkan-Loader-src"

need() { command -v "$1" >/dev/null || { echo "need $1" >&2; exit 1; }; }

if [[ -f "$DLL" && "$(cat "$STAMP" 2>/dev/null || true)" == "$TAG" ]]; then
  echo "ok vulkan loader $TAG → $DLL" >&2
  printf 'export KOTV_WINDOWS_VULKAN_DLL=%q\n' "$DLL"
  exit 0
fi

need git
need cmake
need "${CC:-gcc}"
need "${CXX:-g++}"

mkdir -p "$OUT_DIR"
if [[ ! -d "$SRC/.git" ]]; then
  git clone --filter=blob:none --depth 1 --branch "$TAG" \
    https://github.com/KhronosGroup/Vulkan-Loader.git "$SRC"
else
  git -C "$SRC" fetch --depth 1 origin tag "$TAG" 2>/dev/null || true
  git -C "$SRC" checkout -q "$TAG"
fi

build_dir="$SRC/build-kotv"
rm -rf "$build_dir"
cmake -S "$SRC" -B "$build_dir" \
  -G "MinGW Makefiles" \
  -DCMAKE_BUILD_TYPE=MinSizeRel \
  -DCMAKE_C_COMPILER="${CC:-gcc}" \
  -DCMAKE_CXX_COMPILER="${CXX:-g++}" \
  -DBUILD_TESTS=OFF \
  -DUPDATE_DEPS=ON \
  -DUSE_MASM=OFF \
  -DENABLE_WIN10_ONECORE=OFF

cmake --build "$build_dir" -j"$JOBS"

built=""
for cand in \
  "$build_dir/loader/vulkan-1.dll" \
  "$build_dir/vulkan-1.dll" \
  "$build_dir/bin/vulkan-1.dll"; do
  [[ -f "$cand" ]] && built="$cand" && break
done
if [[ -z "$built" ]]; then
  built="$(find "$build_dir" -name 'vulkan-1.dll' 2>/dev/null | head -1 || true)"
fi
[[ -n "$built" && -f "$built" ]] || {
  echo "ERROR: Vulkan-Loader $TAG build finished but vulkan-1.dll not found under $build_dir" >&2
  find "$build_dir" -maxdepth 4 -type f 2>/dev/null | head -40 >&2 || true
  exit 1
}

cp -f "$built" "$DLL"
printf '%s' "$TAG" >"$STAMP"
echo "built vulkan loader $TAG → $DLL ($(wc -c <"$DLL" | tr -d ' ') bytes)" >&2
printf 'export KOTV_WINDOWS_VULKAN_DLL=%q\n' "$DLL"
