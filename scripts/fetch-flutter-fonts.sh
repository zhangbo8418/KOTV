#!/usr/bin/env bash
# 拉取 Flutter 内嵌开源字体（不进 git，打包/本地构建前执行）。
#   Noto Sans SC Regular + Bold  ≈ 16 MB
#   Noto Color Emoji (WindowsCompatible / COLR) ≈ 10 MB
#   Noto Emoji（黑白轮廓）≈ 2 MB — 仅 Win7 线（KOTV_WIN7=1）需要
# SIL OFL。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/flutter/assets/fonts"
CACHE="${KOTV_CACHE:-$ROOT/.cache}"
mkdir -p "$DEST" "$CACHE"

NOTO_SC_ZIP_URL="${NOTO_SC_ZIP_URL:-https://github.com/notofonts/noto-cjk/releases/download/Sans2.004/18_NotoSansSC.zip}"
EMOJI_COLOR_URL="${NOTO_EMOJI_URL:-https://raw.githubusercontent.com/googlefonts/noto-emoji/main/fonts/NotoColorEmoji_WindowsCompatible.ttf}"
# 黑白轮廓 emoji（非 COLR）；Win7 / 旧 Skia 可画。
EMOJI_MONO_URL="${NOTO_EMOJI_MONO_URL:-https://raw.githubusercontent.com/google/fonts/main/ofl/notoemoji/NotoEmoji%5Bwght%5D.ttf}"

# 仅 Win7 打包需要黑白 emoji；其它平台用系统 emoji。
WANT_MONO=
if [[ "${KOTV_WIN7:-}" == "1" || "${KOTV_FETCH_MONO_EMOJI:-}" == "1" ]]; then
  WANT_MONO=1
fi

need_sc=
need_emoji_color=
need_emoji_mono=
[[ -f "$DEST/NotoSansSC-Regular.otf" && -s "$DEST/NotoSansSC-Regular.otf" ]] || need_sc=1
[[ -f "$DEST/NotoSansSC-Bold.otf" && -s "$DEST/NotoSansSC-Bold.otf" ]] || need_sc=1
[[ -f "$DEST/NotoColorEmoji.ttf" && -s "$DEST/NotoColorEmoji.ttf" ]] || need_emoji_color=1
if [[ -n "$WANT_MONO" ]]; then
  [[ -f "$DEST/NotoEmoji.ttf" && -s "$DEST/NotoEmoji.ttf" ]] || need_emoji_mono=1
fi

if [[ -z "$need_sc" && -z "$need_emoji_color" && -z "$need_emoji_mono" ]]; then
  echo "[fonts] already present:"
  ls -lh "$DEST"/NotoSansSC-Regular.otf "$DEST"/NotoSansSC-Bold.otf "$DEST"/NotoColorEmoji.ttf
  if [[ -n "$WANT_MONO" ]]; then
    ls -lh "$DEST"/NotoEmoji.ttf
  fi
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
ls -lh "$DEST"/NotoSansSC-Regular.otf "$DEST"/NotoSansSC-Bold.otf "$DEST"/NotoColorEmoji.ttf
if [[ -n "$WANT_MONO" && -f "$DEST/NotoEmoji.ttf" ]]; then
  ls -lh "$DEST"/NotoEmoji.ttf
fi
