#!/usr/bin/env bash
# 拉取 Flutter 内嵌开源字体（不进 git，打包/本地构建前执行）。
#   Noto Sans SC Regular + Bold  ≈ 16 MB
#   Noto Color Emoji (WindowsCompatible) ≈ 10 MB
# 合计约 26 MB；SIL OFL。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/flutter/assets/fonts"
CACHE="${KOTV_CACHE:-$ROOT/.cache}"
mkdir -p "$DEST" "$CACHE"

NOTO_SC_ZIP_URL="${NOTO_SC_ZIP_URL:-https://github.com/notofonts/noto-cjk/releases/download/Sans2.004/18_NotoSansSC.zip}"
EMOJI_URL="${NOTO_EMOJI_URL:-https://raw.githubusercontent.com/googlefonts/noto-emoji/main/fonts/NotoColorEmoji_WindowsCompatible.ttf}"

need_sc=
need_emoji=
[[ -f "$DEST/NotoSansSC-Regular.otf" && -s "$DEST/NotoSansSC-Regular.otf" ]] || need_sc=1
[[ -f "$DEST/NotoSansSC-Bold.otf" && -s "$DEST/NotoSansSC-Bold.otf" ]] || need_sc=1
[[ -f "$DEST/NotoColorEmoji.ttf" && -s "$DEST/NotoColorEmoji.ttf" ]] || need_emoji=1

if [[ -z "$need_sc" && -z "$need_emoji" ]]; then
  echo "[fonts] already present:"
  ls -lh "$DEST"/NotoSansSC-Regular.otf "$DEST"/NotoSansSC-Bold.otf "$DEST"/NotoColorEmoji.ttf
  exit 0
fi

download() {
  local url="$1" out="$2"
  if [[ -f "$out" && -s "$out" ]]; then
    return 0
  fi
  echo "[fonts] download $(basename "$out")"
  curl -fL --retry 3 --retry-delay 2 -o "$out.partial" "$url"
  mv -f "$out.partial" "$out"
}

if [[ -n "$need_sc" ]]; then
  zip="$CACHE/18_NotoSansSC.zip"
  download "$NOTO_SC_ZIP_URL" "$zip"
  tmp="$CACHE/NotoSansSC-extract"
  rm -rf "$tmp"
  mkdir -p "$tmp"
  unzip -qo "$zip" -d "$tmp"
  cp -f "$tmp/NotoSansSC-Regular.otf" "$DEST/NotoSansSC-Regular.otf"
  cp -f "$tmp/NotoSansSC-Bold.otf" "$DEST/NotoSansSC-Bold.otf"
  # LICENSE 一并放着，方便审计
  [[ -f "$tmp/LICENSE" ]] && cp -f "$tmp/LICENSE" "$DEST/LICENSE-NotoSansSC.txt"
  rm -rf "$tmp"
fi

if [[ -n "$need_emoji" ]]; then
  download "$EMOJI_URL" "$DEST/NotoColorEmoji.ttf"
fi

echo "[fonts] ready (~$(du -sh "$DEST" | awk '{print $1}')):"
ls -lh "$DEST"/NotoSansSC-Regular.otf "$DEST"/NotoSansSC-Bold.otf "$DEST"/NotoColorEmoji.ttf
