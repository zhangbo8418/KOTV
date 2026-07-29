#!/usr/bin/env bash
# 将仓库完整 runtime/ + kotv-engine 编入 Flutter 应用包。
# 用法:
#   ./scripts/bundle-flutter-runtime.sh <KO影视.app | install-dir>
# macOS Xcode Build Phase / package-flutter-macos.sh / Win·Linux install 目录均可调用。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_RT="$ROOT/runtime"
ENGINE_SRC="$ROOT/flutter/assets/engine/kotv-engine"
[[ -f "$ENGINE_SRC" ]] || ENGINE_SRC="$ROOT/flutter/assets/engine/kotv-engine.exe"
DEST_ROOT="${1:-}"

if [[ -z "$DEST_ROOT" ]]; then
  echo "usage: $0 <KO影视.app | install-dir>" >&2
  exit 1
fi

if [[ ! -d "$SRC_RT" ]]; then
  echo "error: missing $SRC_RT — run scripts/prepare-runtime.sh first" >&2
  exit 1
fi

# 最少要有 jre（JAR 爬虫）、libvlc（页内 VLC）、bridge；页内 MPV 由 media_kit 自带
need_ok=1
for need in jre libvlc bridge; do
  if [[ ! -d "$SRC_RT/$need" && ! -e "$SRC_RT/$need" ]]; then
    echo "error: incomplete runtime, missing $SRC_RT/$need" >&2
    echo "  run: ./scripts/prepare-runtime.sh" >&2
    need_ok=0
  fi
done
[[ "$need_ok" == 1 ]] || exit 1

# 归一：若传入 .app，落到 Contents/Resources/runtime；否则 <dir>/runtime
if [[ "$DEST_ROOT" == *.app || "$DEST_ROOT" == *.app/ ]]; then
  DEST_RT="$DEST_ROOT/Contents/Resources/runtime"
  DEST_ENGINE_DIR="$DEST_ROOT/Contents/Resources/engine"
  DEST_MACOS="$DEST_ROOT/Contents/MacOS"
else
  DEST_RT="$DEST_ROOT/runtime"
  DEST_ENGINE_DIR="$DEST_ROOT"
  DEST_MACOS=""
fi

mkdir -p "$DEST_RT"
echo "==> bundle full runtime -> $DEST_RT"
# 整树同步（保留 dylib symlink）；macOS 用 ditto
if command -v ditto >/dev/null 2>&1 && [[ "$(uname -s)" == Darwin ]]; then
  # 先清再拷，避免残留半包
  rm -rf "$DEST_RT"
  mkdir -p "$DEST_RT"
  ditto "$SRC_RT" "$DEST_RT"
else
  rm -rf "$DEST_RT"
  mkdir -p "$DEST_RT"
  cp -a "$SRC_RT/." "$DEST_RT/"
fi
# 不进包：外部 mpv、残留 libmpv、旧布局顶层 lib/
rm -rf "$DEST_RT/mpv" "$DEST_RT/vlc" "$DEST_RT/lib" "$DEST_RT/libmpv"

# embed 只要 libjvm/libpython + stdlib/modules；去掉 java/python 启动器
chmod +x "$ROOT/scripts/strip-runtime-launchers.sh"
"$ROOT/scripts/strip-runtime-launchers.sh" "$DEST_RT"

# 校验关键子目录
for need in jre python libvlc bridge; do
  if [[ ! -e "$DEST_RT/$need" ]]; then
    echo "error: bundle missing $DEST_RT/$need" >&2
    exit 1
  fi
done
# embed 动态库
if [[ "$(uname -s)" == Darwin ]]; then
  test -f "$DEST_RT/jre/lib/server/libjvm.dylib" || { echo "error: libjvm.dylib missing" >&2; exit 1; }
  test -e "$DEST_RT/python/lib"/libpython*.dylib || { echo "error: libpython missing" >&2; exit 1; }
elif [[ "$(uname -s)" == Linux ]]; then
  test -f "$DEST_RT/jre/lib/server/libjvm.so" || { echo "error: libjvm.so missing" >&2; exit 1; }
  test -e "$DEST_RT/python/lib"/libpython*.so || { echo "error: libpython missing" >&2; exit 1; }
else
  # Windows / MSYS
  test -e "$DEST_RT/jre/bin/server/jvm.dll" -o -e "$DEST_RT/jre/bin/client/jvm.dll" \
    || { echo "error: jvm.dll missing" >&2; exit 1; }
  test -e "$DEST_RT/python/python3.dll" -o -e "$DEST_RT/python/python314.dll" \
    || { echo "error: python3.dll missing" >&2; exit 1; }
fi

# 引擎二进制：优先 assets 里已编好的
if [[ ! -f "$ENGINE_SRC" ]]; then
  echo "==> build Go engine (missing assets)"
  "$ROOT/scripts/build-engine-flutter.sh" || {
    # build-engine-flutter 可能因 cwd 失败，再直接编
    (cd "$ROOT" && go build -o "$ROOT/flutter/assets/engine/kotv-engine" ./cmd/engine)
  }
  ENGINE_SRC="$ROOT/flutter/assets/engine/kotv-engine"
  [[ -f "$ENGINE_SRC" ]] || ENGINE_SRC="$ROOT/flutter/assets/engine/kotv-engine.exe"
fi

if [[ -f "$ENGINE_SRC" ]]; then
  mkdir -p "$DEST_ENGINE_DIR"
  ENG_NAME="$(basename "$ENGINE_SRC")"
  cp -f "$ENGINE_SRC" "$DEST_ENGINE_DIR/$ENG_NAME"
  chmod +x "$DEST_ENGINE_DIR/$ENG_NAME" 2>/dev/null || true
  # 勿放入 Contents/MacOS：Xcode 会对 MacOS 下文件做 codesign，未签名的 Go 二进制会让 Flutter build 失败。
  # 发行包装脚本可再复制到 MacOS，并由包装脚本 / ad-hoc sign 处理。
  # 清理历史残留，避免增量构建把旧引擎留在 MacOS 里导致 CodeSign 失败。
  if [[ -n "$DEST_MACOS" && -z "${KOTV_BUNDLE_ENGINE_TO_MACOS:-}" ]]; then
    rm -f "$DEST_MACOS/kotv-engine" "$DEST_MACOS/kotv-engine.exe" 2>/dev/null || true
  fi
  if [[ -n "${KOTV_BUNDLE_ENGINE_TO_MACOS:-}" && -n "$DEST_MACOS" ]]; then
    mkdir -p "$DEST_MACOS"
    cp -f "$ENGINE_SRC" "$DEST_MACOS/$ENG_NAME"
    chmod +x "$DEST_MACOS/$ENG_NAME" 2>/dev/null || true
    if command -v codesign >/dev/null 2>&1; then
      codesign --force --sign - "$DEST_MACOS/$ENG_NAME" 2>/dev/null || true
    fi
    echo "ok: engine -> $DEST_MACOS/$ENG_NAME"
  fi
  if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - "$DEST_ENGINE_DIR/$ENG_NAME" 2>/dev/null || true
  fi
  echo "ok: engine -> $DEST_ENGINE_DIR/$ENG_NAME"
else
  echo "warning: kotv-engine not found; UI will try assets extract" >&2
fi

echo "ok: runtime components:"
du -sh "$DEST_RT"/* 2>/dev/null | sed 's|^|  |'
