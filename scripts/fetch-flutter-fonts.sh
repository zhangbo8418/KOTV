#!/usr/bin/env bash
# 拉取 Flutter 内嵌开源字体（不进 git）。
# 仅 Win7 打包线使用（KOTV_WIN7=1）；其它平台用系统字体，不内嵌。
#   Noto Sans SC Regular + Bold  ≈ 16 MB
#   Noto Color Emoji (WindowsCompatible / COLR) ≈ 10 MB
#   Noto Emoji（黑白轮廓）≈ 2 MB
# SIL OFL。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/flutter/assets/fonts"
CACHE="${KOTV_CACHE:-$ROOT/.cache}"
mkdir -p "$DEST" "$CACHE"

if [[ "${KOTV_WIN7:-}" != "1" ]]; then
  echo "[fonts] skip: embedded fonts are Win7-only (set KOTV_WIN7=1)"
  exit 0
fi

NOTO_SC_ZIP_URL="${NOTO_SC_ZIP_URL:-https://github.com/notofonts/noto-cjk/releases/download/Sans2.004/18_NotoSansSC.zip}"
EMOJI_COLOR_URL="${NOTO_EMOJI_URL:-https://raw.githubusercontent.com/googlefonts/noto-emoji/main/fonts/NotoColorEmoji_WindowsCompatible.ttf}"
EMOJI_MONO_URL="${NOTO_EMOJI_MONO_URL:-https://raw.githubusercontent.com/google/fonts/main/ofl/notoemoji/NotoEmoji%5Bwght%5D.ttf}"

need_sc=
need_emoji_color=
need_emoji_mono=
[[ -f "$DEST/NotoSansSC-Regular.otf" && -s "$DEST/NotoSansSC-Regular.otf" ]] || need_sc=1
[[ -f "$DEST/NotoSansSC-Bold.otf" && -s "$DEST/NotoSansSC-Bold.otf" ]] || need_sc=1
[[ -f "$DEST/NotoColorEmoji.ttf" && -s "$DEST/NotoColorEmoji.ttf" ]] || need_emoji_color=1
[[ -f "$DEST/NotoEmoji.ttf" && -s "$DEST/NotoEmoji.ttf" ]] || need_emoji_mono=1

if [[ -z "$need_sc" && -z "$need_emoji_color" && -z "$need_emoji_mono" ]]; then
  echo "[fonts] already present (Win7):"
  ls -lh "$DEST"/NotoSansSC-Regular.otf "$DEST"/NotoSansSC-Bold.otf "$DEST"/NotoColorEmoji.ttf "$DEST"/NotoEmoji.ttf
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
  [[ -f "$tmp/LICENSE" ]] && cp -f "$tmp/LICENSE" "$DEST/LICENSE-NotoSansSC.txt"
  rm -rf "$tmp"
fi

if [[ -n "$need_emoji_color" ]]; then
  download "$EMOJI_COLOR_URL" "$DEST/NotoColorEmoji.ttf"
fi

if [[ -n "$need_emoji_mono" ]]; then
  download "$EMOJI_MONO_URL" "$DEST/NotoEmoji.ttf"
fi

echo "[fonts] ready (~$(du -sh "$DEST" | awk '{print $1}')):"
ls -lh "$DEST"/NotoSansSC-Regular.otf "$DEST"/NotoSansSC-Bold.otf "$DEST"/NotoColorEmoji.ttf "$DEST"/NotoEmoji.ttf
