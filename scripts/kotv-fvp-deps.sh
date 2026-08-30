#!/usr/bin/env bash
# fvp / mdk-sdk：默认跟 GitHub Release 最新（与 Chromium 同一策略），避免写死版本、也避免 SourceForge nightly。
# 用法：在 package-*.sh 里 `source "$ROOT/scripts/kotv-fvp-deps.sh"`
# 可选覆盖：FVP_DEPS_URL=https://github.com/wang-bin/mdk-sdk/releases/download/vX.Y.Z
#
# 注意：fvp 的 darwin podspec 会写 `mdk ~> X.Y.Z`（0.38.1 起是 ~> 0.38.0）。
# 本地 pod 的 s.version 用该下限才能过 CocoaPods；实际解压的是上面解析到的最新 SDK。

kotv_fvp_deps_url() {
  if [[ -n "${FVP_DEPS_URL:-}" ]]; then
    echo "$FVP_DEPS_URL"
    return
  fi
  local resolved=""
  resolved="$(_kotv_python - <<'PY' || true
import json, os, sys, time, urllib.request

url = "https://api.github.com/repos/wang-bin/mdk-sdk/releases/latest"
token = (os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN") or "").strip()
headers = {
    "Accept": "application/vnd.github+json",
    "User-Agent": "KOTV-fvp-deps",
    "X-GitHub-Api-Version": "2022-11-28",
}
if token:
    headers["Authorization"] = f"Bearer {token}"

last_err = None
for attempt in range(1, 6):
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.load(resp)
        tag = (data.get("tag_name") or "").strip()
        if not tag:
            raise RuntimeError("empty tag_name")
        print(f"https://github.com/wang-bin/mdk-sdk/releases/download/{tag}")
        raise SystemExit(0)
    except Exception as e:
        last_err = str(e)
        if attempt < 5:
            time.sleep(attempt * 2)
            continue
        print(f"WARN: mdk-sdk latest lookup failed: {last_err}", file=sys.stderr)
        raise SystemExit(1)
PY
)"
  if [[ -n "$resolved" ]]; then
    echo "$resolved"
    return
  fi
  echo "WARN: mdk-sdk latest lookup failed; fallback v0.38.0" >&2
  echo "https://github.com/wang-bin/mdk-sdk/releases/download/v0.38.0"
}

kotv_mdk_sdk_ver() {
  local url
  url="$(kotv_fvp_deps_url)"
  echo "${url##*/v}"
}

# 导出给 fvp cmake/deps.cmake（Android / Windows / Linux）。
kotv_export_fvp_deps() {
  export FVP_DEPS_URL="$(kotv_fvp_deps_url)"
  FVP_DEPS_URL="${FVP_DEPS_URL//$'\r'/}"
  export FVP_DEPS_URL
  echo "==> FVP_DEPS_URL=$FVP_DEPS_URL"
}

# GitHub mdk-sdk v0.37+ 不再发布 mdk-sdk-windows-x64.7z，改为 *-vsYYYY.7z。
# fvp cmake 仍拼旧文件名；CMake file(DOWNLOAD) 遇 404 会写成空文件，随后解压失败。
kotv_mdk_windows_assets() {
  if [[ -n "${KOTV_MDK_WINDOWS_ASSET:-}" ]]; then
    echo "$KOTV_MDK_WINDOWS_ASSET"
    echo "mdk-sdk-windows-x64.7z"
    return
  fi
  local names=""
  names="$(_kotv_python - <<'PY' || true
import json, os, re, sys, time, urllib.request

base = (os.environ.get("FVP_DEPS_URL") or "").rstrip("/")
tag = ""
m = re.search(r"/download/([^/]+)$", base)
if m:
    tag = m.group(1)
url = (
    f"https://api.github.com/repos/wang-bin/mdk-sdk/releases/tags/{tag}"
    if tag
    else "https://api.github.com/repos/wang-bin/mdk-sdk/releases/latest"
)
token = (os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN") or "").strip()
headers = {
    "Accept": "application/vnd.github+json",
    "User-Agent": "KOTV-fvp-deps",
    "X-GitHub-Api-Version": "2022-11-28",
}
if token:
    headers["Authorization"] = f"Bearer {token}"

data = None
for attempt in range(1, 6):
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.load(resp)
        break
    except Exception:
        if attempt < 5:
            time.sleep(attempt * 2)
            continue
        raise SystemExit(1)

cands = []
for asset in data.get("assets") or []:
    name = asset.get("name") or ""
    nl = name.lower()
    if not nl.endswith(".7z") or "windows" not in nl:
        continue
    if "ltl" in nl or "clang" in nl or "uwp" in nl:
        continue
    if "x64" in nl or re.search(r"windows-vs\d", nl):
        cands.append(name)

def rank(n):
    nl = n.lower()
    if "x64" in nl and "vs" in nl:
        return 0
    if "x64" in nl:
        return 1
    if "vs" in nl:
        return 2
    return 3

for name in sorted(set(cands), key=rank):
    sys.stdout.write(name.replace("\r", "") + "\n")
PY
)"
  if [[ -n "$names" ]]; then
    echo "$names"
  else
    echo "mdk-sdk-windows-x64-vs2026.7z"
  fi
  echo "mdk-sdk-windows-x64.7z"
}

_kotv_repo_root() {
  if [[ -n "${ROOT:-}" ]]; then
    echo "$ROOT"
    return
  fi
  (cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
}

_kotv_unix_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -u "$1"
  else
    echo "$1"
  fi
}

_kotv_python() {
  if command -v python3 >/dev/null 2>&1; then
    python3 "$@"
  elif command -v python >/dev/null 2>&1; then
    python "$@"
  elif command -v py >/dev/null 2>&1; then
    py -3 "$@"
  else
    return 1
  fi
}

# 解析 flutter pub get 之后 fvp 插件根目录（hosted pub-cache）。
kotv_fvp_package_root() {
  local repo cfg
  repo="$(_kotv_repo_root)"
  cfg="$repo/flutter/.dart_tool/package_config.json"
  if [[ ! -f "$cfg" ]]; then
    echo "error: missing $cfg — run flutter pub get first" >&2
    return 1
  fi
  _kotv_python - "$cfg" <<'PY'
import json, os, sys
from urllib.parse import unquote, urlparse
from urllib.request import url2pathname

cfg = sys.argv[1]
with open(cfg, encoding="utf-8") as f:
    data = json.load(f)
for pkg in data.get("packages", []):
    if pkg.get("name") != "fvp":
        continue
    uri = pkg.get("rootUri") or ""
    if uri.startswith("file:"):
        path = url2pathname(unquote(urlparse(uri).path))
    else:
        path = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(cfg)), uri))
    sys.stdout.write(path)
    sys.exit(0)
sys.exit(1)
PY
}

_kotv_extract_7z() {
  local archive="$1" dest="$2"
  mkdir -p "$dest"
  if command -v cmake >/dev/null 2>&1; then
    if (cd "$dest" && cmake -E tar xf "$archive" >/dev/null); then
      return 0
    fi
    echo "==> cmake tar failed, trying 7z"
  fi
  if command -v 7z >/dev/null 2>&1; then
    7z x -y "-o$dest" "$archive" >/dev/null
    return
  fi
  echo "error: need cmake or 7z to extract $archive" >&2
  return 1
}

# 把 GitHub 上真实的 Windows SDK 解到 fvp/windows，让 cmake 跳过已失效的旧文件名下载。
kotv_ensure_mdk_windows_sdk() {
  local repo ver dest stamp archive_dir archive url fvp_root win_dir name
  repo="$(_kotv_repo_root)"
  ver="$(kotv_mdk_sdk_ver)"
  fvp_root="$(kotv_fvp_package_root)" || return 1
  fvp_root="$(_kotv_unix_path "$fvp_root")"
  win_dir="$fvp_root/windows"
  dest="$win_dir"
  stamp="$win_dir/.kotv-mdk-sdk"
  mkdir -p "$win_dir"

  if [[ -f "$stamp" && "$(cat "$stamp" 2>/dev/null)" == "$ver" && -f "$win_dir/mdk-sdk/lib/cmake/FindMDK.cmake" ]]; then
    echo "==> mdk windows sdk ready ($ver): $win_dir/mdk-sdk"
    return 0
  fi

  archive_dir="$repo/dist/_mdk-sdk"
  mkdir -p "$archive_dir"

  archive=""
  url=""
  for name in $(kotv_mdk_windows_assets); do
    name="${name//$'\r'/}"
    [[ -n "$name" ]] || continue
    url="$(kotv_fvp_deps_url)/$name"
    url="${url//$'\r'/}"
    archive="$archive_dir/$name"
    echo "==> fetch mdk windows sdk $ver: $url"
    if curl -fL --retry 5 --retry-delay 2 -o "$archive" "$url"; then
      if [[ -s "$archive" ]]; then
        break
      fi
    fi
    rm -f "$archive"
    archive=""
  done
  [[ -n "$archive" && -s "$archive" ]] || {
    echo "error: failed to download mdk-sdk windows archive from $(kotv_fvp_deps_url)" >&2
    return 1
  }

  rm -rf "$win_dir/mdk-sdk"
  _kotv_extract_7z "$archive" "$dest"
  [[ -f "$win_dir/mdk-sdk/lib/cmake/FindMDK.cmake" ]] || {
    echo "error: extracted archive missing FindMDK.cmake" >&2
    return 1
  }
  # fvp cmake 仍查找旧文件名；放一份有效 7z，避免残留空文件被再次解压。
  cp -f "$archive" "$win_dir/mdk-sdk-windows-x64.7z"
  echo "$ver" > "$stamp"
  echo "==> mdk windows sdk prepared ($ver): $win_dir/mdk-sdk"
}

# macOS：准备本地 mdk pod（KOTV_MDK_POD_PATH），供 Podfile 使用。
kotv_ensure_mdk_apple_pod() {
  local dest="${KOTV_MDK_POD_PATH:-/tmp/mdk-sdk-local}"
  local tarball="${KOTV_MDK_APPLE_TAR:-/tmp/mdk-sdk-apple.tar.xz}"
  local url ver stamp
  url="$(kotv_fvp_deps_url)/mdk-sdk-apple.tar.xz"
  ver="$(kotv_mdk_sdk_ver)"
  stamp="$dest/.kotv-mdk-sdk"

  mkdir -p "$dest"
  if [[ -f "$stamp" && "$(cat "$stamp" 2>/dev/null)" == "$ver" ]] && { [[ -d "$dest/mdk.xcframework" ]] || [[ -d "$dest/mdk-sdk/lib/mdk.xcframework" ]]; }; then
    kotv_write_mdk_podspec "$dest"
    export KOTV_MDK_POD_PATH="$dest"
    echo "==> mdk apple pod ready ($ver): $KOTV_MDK_POD_PATH"
    return 0
  fi

  echo "==> fetch mdk-sdk-apple $ver: $url"
  curl -fL --retry 5 --retry-delay 2 -o "$tarball" "$url"
  rm -rf "$dest"
  mkdir -p "$dest"
  tar -xJf "$tarball" -C "$dest"
  kotv_write_mdk_podspec "$dest"
  echo "$ver" > "$stamp"
  export KOTV_MDK_POD_PATH="$dest"
  echo "==> mdk apple pod prepared ($ver): $KOTV_MDK_POD_PATH"
}

# fvp podspec 会写 `mdk ~> X.Y.Z`。本地 pod 的 s.version 用该下限以过 CocoaPods；
# 实际解压的仍是 GitHub 解析到的最新 SDK。
_kotv_mdk_pod_version() {
  local fvp_root spec ver
  fvp_root="$(kotv_fvp_package_root 2>/dev/null)" || true
  if [[ -n "${fvp_root:-}" ]]; then
    for spec in "$fvp_root/darwin/fvp.podspec" "$fvp_root/macos/fvp.podspec" "$fvp_root/ios/fvp.podspec"; do
      [[ -f "$spec" ]] || continue
      ver="$(perl -ne 'print $1 if /dependency\s+['\''"]mdk['\''"]\s*,\s*['\''"]~>\s*([0-9.]+)/' "$spec")"
      if [[ -n "$ver" ]]; then
        echo "$ver"
        return
      fi
    done
  fi
  kotv_mdk_sdk_ver
}

kotv_write_mdk_podspec() {
  local dest="$1"
  local ver
  ver="$(_kotv_mdk_pod_version)"
  ver="${ver#v}"
  cat > "$dest/mdk.podspec" <<EOF
Pod::Spec.new do |s|
  s.name             = 'mdk'
  s.version          = '${ver}'
  s.summary          = 'Multimedia Development Kit'
  s.homepage         = 'https://github.com/wang-bin/mdk-sdk'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Wang Bin' => 'wbsecg1@gmail.com' }
  s.osx.deployment_target = '10.13'
  s.ios.deployment_target = '12.0'
  s.source           = { :path => '.' }
  s.vendored_frameworks = 'mdk.xcframework'
end
EOF
  if [[ -d "$dest/mdk-sdk/lib/mdk.xcframework" ]]; then
    ln -sfn mdk-sdk/lib/mdk.xcframework "$dest/mdk.xcframework"
    if [[ "$(uname -s)" == "Darwin" ]]; then
      sed -i '' "s|mdk.xcframework|mdk-sdk/lib/mdk.xcframework|" "$dest/mdk.podspec"
    else
      sed -i "s|mdk.xcframework|mdk-sdk/lib/mdk.xcframework|" "$dest/mdk.podspec"
    fi
  fi
}
