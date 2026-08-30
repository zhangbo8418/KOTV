#!/usr/bin/env bash
# 桌面 libmpv 分发（页内 MPV P2）：放入 flutter/assets/mpv-libs/{windows,linux,macos}/
# 构建时 CMake/install 会拷到可执行文件旁的 libmpv/。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSET="$ROOT/flutter/assets/mpv-libs"
mkdir -p "$ASSET/windows" "$ASSET/linux" "$ASSET/macos"

copy_if() {
  local src="$1" dest="$2"
  if [[ -f "$src" ]]; then
    cp -f "$src" "$dest"
    echo "ok $(basename "$dest") <- $src"
    return 0
  fi
  return 1
}

echo "==> fetch desktop libmpv → $ASSET"

case "$(uname -s)" in
  Darwin)
    for p in \
      /opt/homebrew/lib/libmpv.dylib \
      /usr/local/lib/libmpv.dylib \
      /opt/homebrew/opt/mpv/lib/libmpv.dylib; do
      if copy_if "$p" "$ASSET/macos/libmpv.dylib"; then break; fi
    done
    if [[ ! -f "$ASSET/macos/libmpv.dylib" ]]; then
      echo "macOS: brew install mpv 后重试，或手动复制 libmpv.dylib → $ASSET/macos/"
    fi
    ;;
  Linux)
    for p in \
      /usr/lib/x86_64-linux-gnu/libmpv.so.2 \
      /usr/lib/aarch64-linux-gnu/libmpv.so.2 \
      /usr/lib64/libmpv.so.2; do
      if copy_if "$p" "$ASSET/linux/libmpv.so.2"; then break; fi
    done
    if [[ ! -f "$ASSET/linux/libmpv.so.2" ]]; then
      echo "Linux: apt install libmpv2 后重试，或手动复制 libmpv.so.2 → $ASSET/linux/"
    fi
    ;;
  MINGW*|MSYS*|CYGWIN*)
    echo "Windows: 请从 mpv-winbuild-cmake 发行包复制 mpv-2.dll → $ASSET/windows/"
    ;;
  *)
    echo "当前 OS $(uname -s)：请手动放置 libmpv 到 $ASSET/{windows,linux,macos}/"
    ;;
esac

du -sh "$ASSET"/* 2>/dev/null || true
echo "==> done"
