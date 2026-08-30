#!/usr/bin/env bash
# 桌面 libmpv 预编译拉取（打进安装包；开发机/CI 均无需 brew/apt 编译）。
# 产物：flutter/assets/mpv-libs/{windows,linux,macos}/
# 可选：KOTV_BUILD_MPV_FROM_SOURCE=1 时走 build-desktop-mpv-from-source.sh（仅 CI 兜底）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSET="$ROOT/flutter/assets/mpv-libs"
mkdir -p "$ASSET/windows" "$ASSET/linux" "$ASSET/macos"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing command: $1" >&2; exit 1; }
}

extract_7z() {
  local archive="$1" dest="$2"
  mkdir -p "$dest"
  if command -v 7z >/dev/null 2>&1; then
    7z x -y "-o$dest" "$archive" >/dev/null
  elif command -v 7za >/dev/null 2>&1; then
    7za x -y "-o$dest" "$archive" >/dev/null
  else
    echo "need 7z to extract $archive" >&2
    exit 1
  fi
}

extract_deb() {
  local deb="$1" dest="$2"
  mkdir -p "$dest"
  if command -v dpkg-deb >/dev/null 2>&1; then
    dpkg-deb -x "$deb" "$dest"
    return
  fi
  need_cmd ar
  need_cmd tar
  local tmp
  tmp="$(mktemp -d)"
  cp -f "$deb" "$tmp/pkg.deb"
  (cd "$tmp" && ar x pkg.deb && tar xf data.tar.* -C "$dest")
  rm -rf "$tmp"
}

marker_ok() {
  local f="$1" min="${2:-100000}"
  [[ -f "$f" && "$(wc -c <"$f" | tr -d ' ')" -ge "$min" ]]
}

fetch_windows() {
  local out="$ASSET/windows/mpv-2.dll"
  local kind_file="$ASSET/windows/.kind"
  local want="prebuilt"
  if [[ "${KOTV_BUILD_MPV_AV3A:-}" == "1" ]]; then
    want="av3a"
  elif [[ "${KOTV_WIN7:-}" == "1" ]]; then
    want="win7"
  fi

  local sibling_ok=0
  if find "$ASSET/windows" -maxdepth 1 -iname 'libplacebo*.dll' 2>/dev/null | grep -q .; then
    sibling_ok=1
  fi

  # Win7 与 Win10 一样：KOTV_BUILD_MPV_AV3A=1 时走 Vulkan+AV3A 源码包。
  if [[ "$want" == "av3a" ]]; then
    if marker_ok "$out" 500000 && grep -aqE 'libarcdav3a|AV3A Audio Vivid' "$out" 2>/dev/null \
      && [[ "$(cat "$kind_file" 2>/dev/null || true)" == "av3a" ]] \
      && [[ "$sibling_ok" == 1 ]]; then
      echo "ok windows/mpv-2.dll (cached AV3A + sibling dlls)"
      return
    fi
    echo "==> windows libmpv: source build with AV3A (FongMi FFmpeg + MinGW)"
    "$ROOT/scripts/build-desktop-mpv-from-source.sh" windows
    echo av3a > "$kind_file"
    return
  fi

  if marker_ok "$out" 500000 && [[ "$(cat "$kind_file" 2>/dev/null || true)" == "$want" ]] \
    && [[ "$sibling_ok" == 1 ]]; then
    echo "ok windows/mpv-2.dll (cached $want + sibling dlls)"
    return
  fi

  local url="${KOTV_MPV_WIN_URL:-}"
  if [[ -z "$url" ]]; then
    # 非 v3：老 CPU 可用；Win7 仍须再拷整包 DLL（不能只留 libmpv）。
    url="$(curl -fsSL "https://api.github.com/repos/shinchiro/mpv-winbuild-cmake/releases/latest" \
      | grep -Eo 'https://[^"]+mpv-dev-x86_64-[0-9]+[^"]+\.7z' | grep -v '\-v3-' | head -1 || true)"
    if [[ -z "$url" ]]; then
      url="$(curl -fsSL "https://api.github.com/repos/shinchiro/mpv-winbuild-cmake/releases" \
        | grep -Eo 'https://[^"]+mpv-dev-x86_64-[0-9]+[^"]+\.7z' | grep -v '\-v3-' | head -1 || true)"
    fi
  fi
  [[ -n "$url" ]] || { echo "ERROR: cannot resolve Windows libmpv URL (set KOTV_MPV_WIN_URL)" >&2; exit 1; }

  need_cmd curl
  local tmp archive dir
  tmp="$(mktemp -d)"
  archive="$tmp/mpv-win.7z"
  dir="$tmp/extract"
  echo "GET $url"
  curl -fL --retry 5 --retry-delay 2 -o "$archive" "$url"
  extract_7z "$archive" "$dir"
  local dll=""
  for cand in "$dir"/libmpv-2.dll "$dir"/mpv-2.dll; do
    [[ -f "$cand" ]] && dll="$cand" && break
  done
  if [[ -z "$dll" ]]; then
    dll="$(find "$dir" \( -iname 'libmpv-2.dll' -o -iname 'mpv-2.dll' \) 2>/dev/null | head -1 || true)"
  fi
  [[ -n "$dll" && -f "$dll" ]] || { echo "ERROR: libmpv dll not found in $url" >&2; exit 1; }
  mkdir -p "$ASSET/windows"
  find "$dir" -type f \( -iname '*.dll' -o -iname '*.pdb' \) -exec cp -f {} "$ASSET/windows/" \;
  cp -f "$dll" "$out"
  echo "$want" > "$kind_file"
  rm -rf "$tmp"
  echo "ok windows/mpv-2.dll ($(wc -c <"$out" | tr -d ' ') bytes) kind=$want (+ sibling dlls)"
}

fetch_linux() {
  local out="$ASSET/linux/libmpv.so.2"
  if [[ "${KOTV_BUILD_MPV_AV3A:-}" == "1" ]]; then
    if marker_ok "$out" 500000 && grep -aqE 'libarcdav3a|AV3A Audio Vivid' "$out" 2>/dev/null; then
      echo "ok linux/libmpv.so.2 (cached AV3A)"
      return
    fi
    echo "==> linux libmpv: source build with AV3A (FongMi FFmpeg + libarcdav3a)"
    "$ROOT/scripts/build-desktop-mpv-from-source.sh" linux
    return
  fi
  marker_ok "$out" 500000 && { echo "ok linux/libmpv.so.2 (cached)"; return; }

  local deb_url="${KOTV_MPV_LINUX_DEB_URL:-}"
  if [[ -z "$deb_url" ]]; then
    deb_url="http://archive.ubuntu.com/ubuntu/pool/universe/m/mpv/libmpv2_0.37.0-1ubuntu4_amd64.deb"
  fi
  need_cmd curl
  local tmp deb dest so ok=0
  tmp="$(mktemp -d)"
  deb="$tmp/libmpv.deb"
  dest="$tmp/root"
  for deb_url in \
    "${KOTV_MPV_LINUX_DEB_URL:-}" \
    "http://archive.ubuntu.com/ubuntu/pool/universe/m/mpv/libmpv2_0.37.0-1ubuntu4_amd64.deb" \
    "http://archive.ubuntu.com/ubuntu/pool/universe/m/mpv/libmpv1_0.34.1-1ubuntu3_amd64.deb"; do
    [[ -n "$deb_url" ]] || continue
    echo "GET $deb_url"
    if curl -fL --retry 3 --retry-delay 2 -o "$deb" "$deb_url"; then
      ok=1
      break
    fi
  done
  [[ "$ok" == 1 ]] || { echo "ERROR: cannot download Linux libmpv deb" >&2; exit 1; }
  extract_deb "$deb" "$dest"
  so="$(find "$dest" -name 'libmpv.so.2' -o -name 'libmpv.so.1' 2>/dev/null | head -1 || true)"
  [[ -n "$so" && -f "$so" ]] || { echo "ERROR: libmpv.so not in deb" >&2; exit 1; }
  cp -f "$so" "$out"
  rm -rf "$tmp"
  echo "ok linux/libmpv.so.2 ($(wc -c <"$out" | tr -d ' ') bytes)"
}

fetch_macos() {
  local out="$ASSET/macos/libmpv.dylib"
  if [[ "${KOTV_BUILD_MPV_AV3A:-}" == "1" ]]; then
    if marker_ok "$out" 500000 && grep -aqE 'libarcdav3a|AV3A Audio Vivid' "$out" 2>/dev/null; then
      echo "ok macOS/libmpv.dylib (cached AV3A)"
      return
    fi
    echo "==> macOS libmpv: source build with AV3A (FongMi FFmpeg + libarcdav3a)"
    if [[ "${KOTV_MPV_MACOS_ARCH:-$(uname -m)}" == "x86_64" && "$(uname -m)" == "arm64" ]]; then
      arch -x86_64 "$ROOT/scripts/build-desktop-mpv-from-source.sh" macos
    else
      "$ROOT/scripts/build-desktop-mpv-from-source.sh" macos
    fi
    return
  fi
  marker_ok "$out" 500000 && { echo "ok macOS/libmpv.dylib (cached)"; return; }

  if [[ -n "${KOTV_MPV_MACOS_URL:-}" ]]; then
    need_cmd curl
    echo "GET $KOTV_MPV_MACOS_URL"
    curl -fL --retry 5 --retry-delay 2 -o "$out" "$KOTV_MPV_MACOS_URL"
    marker_ok "$out" 500000 || { echo "ERROR: bad macOS libmpv download" >&2; exit 1; }
    echo "ok macOS/libmpv.dylib ($(wc -c <"$out" | tr -d ' ') bytes)"
    return
  fi

  local want_arch="${KOTV_MPV_MACOS_ARCH:-$(uname -m)}"
  local brew_prefix=""
  # CI：从 Homebrew bottle 复制预编译 dylib（非源码编译）；x64 交叉包用 arch -x86_64 brew
  if [[ "${CI:-}" == "true" ]] && command -v brew >/dev/null 2>&1; then
    if [[ "$want_arch" == "x86_64" && "$(uname -m)" == "arm64" ]]; then
      arch -x86_64 brew list mpv &>/dev/null 2>&1 || arch -x86_64 brew install mpv
      brew_prefix="$(arch -x86_64 brew --prefix mpv 2>/dev/null || echo /usr/local/opt/mpv)"
    else
      brew list mpv &>/dev/null 2>&1 || brew install mpv
      brew_prefix="$(brew --prefix mpv 2>/dev/null || true)"
    fi
  fi

  for p in \
    "${brew_prefix:+$brew_prefix/lib/libmpv.dylib}" \
    /usr/local/opt/mpv/lib/libmpv.dylib \
    /usr/local/lib/libmpv.dylib \
    /opt/homebrew/opt/mpv/lib/libmpv.dylib \
    /opt/homebrew/lib/libmpv.dylib; do
    [[ -n "$p" && -f "$p" ]] || continue
    cp -f "$p" "$out"
    echo "ok macOS/libmpv.dylib <- $p"
    return
  done

  if [[ "${KOTV_BUILD_MPV_FROM_SOURCE:-}" == "1" && -x "$ROOT/scripts/build-desktop-mpv-from-source.sh" ]]; then
    "$ROOT/scripts/build-desktop-mpv-from-source.sh" macos
    marker_ok "$out" 500000 && return
  fi

  echo "ERROR: macOS libmpv not available. CI 会自动拉 bottle；本地请设 KOTV_MPV_MACOS_URL 或 KOTV_BUILD_MPV_FROM_SOURCE=1" >&2
  exit 1
}

fetch_with_fallback() {
  local name="$1"
  shift
  if ( "$@" ); then
    return 0
  fi
  if [[ "${KOTV_BUILD_MPV_FROM_SOURCE:-}" == "1" && "$name" != "windows" ]]; then
    echo "WARN: prebuilt $name failed; trying build-desktop-mpv-from-source.sh $name"
    "$ROOT/scripts/build-desktop-mpv-from-source.sh" "$name"
    return $?
  fi
  return 1
}

detect_desktop_plat() {
  case "$(uname -s 2>/dev/null)" in
    Linux*) echo linux ;;
    Darwin*) echo macos ;;
    MINGW*|MSYS*|CYGWIN*) echo windows ;;
    *)
      if [[ "${OS:-}" == "Windows_NT" ]]; then
        echo windows
      fi
      ;;
  esac
}

if [[ -z "${KOTV_FETCH_DESKTOP_PLAT:-}" ]]; then
  auto="$(detect_desktop_plat || true)"
  if [[ -n "$auto" ]]; then
    KOTV_FETCH_DESKTOP_PLAT="$auto"
    echo "==> auto KOTV_FETCH_DESKTOP_PLAT=$KOTV_FETCH_DESKTOP_PLAT"
  fi
fi

echo "==> fetch desktop libmpv (prebuilt, no local compile) → $ASSET"
if [[ -n "${KOTV_FETCH_DESKTOP_PLAT:-}" ]]; then
  case "${KOTV_FETCH_DESKTOP_PLAT}" in
    windows|win) fetch_with_fallback windows fetch_windows ;;
    linux) fetch_with_fallback linux fetch_linux ;;
    macos|darwin) fetch_with_fallback macos fetch_macos ;;
    *) echo "unknown KOTV_FETCH_DESKTOP_PLAT=${KOTV_FETCH_DESKTOP_PLAT}" >&2; exit 1 ;;
  esac
else
  fetch_with_fallback windows fetch_windows
  fetch_with_fallback linux fetch_linux
  fetch_with_fallback macos fetch_macos
fi
KOTV_VERIFY_PLAT="${KOTV_VERIFY_PLAT:-${KOTV_FETCH_DESKTOP_PLAT:-}}" \
KOTV_EXPECT_MPV_AV3A="${KOTV_EXPECT_MPV_AV3A:-${KOTV_BUILD_MPV_AV3A:-}}" \
"$ROOT/scripts/verify-desktop-mpv-libs.sh" || {
  if [[ "${KOTV_BUILD_MPV_FROM_SOURCE:-}" == "1" || "${KOTV_BUILD_MPV_AV3A:-}" == "1" ]]; then
    echo "WARN: verify failed after fetch; check source build logs"
  else
    exit 1
  fi
}
du -sh "$ASSET"/* 2>/dev/null || true
echo "==> done"
