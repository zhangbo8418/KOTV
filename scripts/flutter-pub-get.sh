#!/usr/bin/env bash
# 统一 flutter pub get：Win7 / Dart 3.3 线自动先跑 adapt，避免 video_player_android 2.11 要 SDK ^3.10。
# 主线：fvp 跟 pub.dev 最新（与 runtime Chromium 跟仓库最新同一策略）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

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

_kotv_pub_cache() {
  echo "${PUB_CACHE:-${PUB_CACHE_DIR:-$HOME/.pub-cache}}"
}

_kotv_pub_host_leaf() {
  case "${PUB_HOSTED_URL:-}" in
    *flutter-io.cn*) echo "pub.flutter-io.cn" ;;
    *) echo "pub.dev" ;;
  esac
}

# 若 pub-cache 还没有包，从 pub.dev 拉 archive（不经过 SDK 校验）。失败即返回非 0。
_kotv_ensure_hosted_pkg() {
  local name="$1" ver="$2"
  local cache host_leaf dest url inner idir
  cache="$(_kotv_pub_cache)"
  host_leaf="$(_kotv_pub_host_leaf)"
  dest="$cache/hosted/$host_leaf/${name}-${ver}"
  if [[ -f "$dest/pubspec.yaml" ]]; then
    return 0
  fi
  echo "==> prefetch ${name}-${ver} into $dest"
  mkdir -p "$dest"
  url="https://pub.dev/api/archives/${name}-${ver}.tar.gz"
  if ! curl -fsSL -A 'KOTV-flutter-pub-get' "$url" | tar -xz -C "$dest"; then
    echo "ERROR: failed to prefetch ${name}-${ver} from $url" >&2
    rm -rf "$dest"
    return 1
  fi
  if [[ ! -f "$dest/pubspec.yaml" ]]; then
    inner="$(find "$dest" -maxdepth 2 -name pubspec.yaml | head -1 || true)"
    if [[ -n "$inner" ]]; then
      idir="$(dirname "$inner")"
      shopt -s dotglob
      mv "$idir"/* "$dest"/ 2>/dev/null || true
      shopt -u dotglob
    fi
  fi
  if [[ ! -f "$dest/pubspec.yaml" ]]; then
    echo "ERROR: prefetch ${name}-${ver} produced no pubspec.yaml" >&2
    rm -rf "$dest"
    return 1
  fi
  return 0
}

# 只放宽 FVP 0.39 与 video_player_platform_interface 6.3.x 的 environment。
# 保持 fvp 对 vppi 的 >=6.3.0（6.2 无 VideoViewType）。若缓存里被误改成 >=6.2.0 则改回。
_kotv_relax_win7_sdk_constraints() {
  local cache
  cache="$(_kotv_pub_cache)"
  _kotv_python - "$cache" <<'PY'
import pathlib, re, sys

cache = pathlib.Path(sys.argv[1]) / "hosted"
TARGET = '''environment:
  sdk: ">=3.3.0 <4.0.0"
  flutter: ">=3.19.0"'''
env_re = re.compile(r"environment:\n(?:  [^\n]+\n)+", re.MULTILINE)

def needs_relax(block: str) -> bool:
    sdk = re.search(r"sdk:\s*[\"']?([^\"'\n]+)", block)
    fl = re.search(r"flutter:\s*[\"']?([^\"'\n]+)", block)
    if fl and re.search(r">=\s*3\.(2[2-9]|[3-9][0-9])", fl.group(1)):
        return True
    if sdk and re.search(r"\^3\.(4|5|6|7|8|9|[1-9][0-9])", sdk.group(1)):
        return True
    if sdk and re.search(r">=\s*3\.(4|5|6|7|8|9|[1-9][0-9])", sdk.group(1)):
        return True
    return False

def relax_file(pubspec: pathlib.Path) -> bool:
    try:
        text = pubspec.read_text(encoding="utf-8")
    except OSError:
        return False
    changed = False
    m = env_re.search(text)
    if m and needs_relax(m.group(0)):
        text = text[: m.start()] + TARGET + "\n" + text[m.end() :]
        changed = True
        print(f"==> relaxed SDK constraints: {pubspec.parent.name}")
    # 误把 fvp 的 vppi 下界改成 6.2 会导致「解析过、编译缺 VideoViewType」。
    if pubspec.parent.name.startswith("fvp-"):
        text2, n = re.subn(
            r"video_player_platform_interface:\s*['\"]?>=6\.2\.0['\"]?",
            "video_player_platform_interface: '>=6.3.0'",
            text,
        )
        if n:
            text = text2
            changed = True
            print(f"==> restored fvp platform_interface >=6.3.0: {pubspec.parent.name}")
    if changed:
        pubspec.write_text(text, encoding="utf-8")
    return changed

targets = []
if cache.is_dir():
    targets.extend(cache.glob("*/fvp-0.39.*/pubspec.yaml"))
    targets.extend(cache.glob("*/video_player_platform_interface-6.3.*/pubspec.yaml"))

if not targets:
    print("ERROR: no fvp-0.39.* / video_player_platform_interface-6.3.* in pub-cache", file=sys.stderr)
    sys.exit(1)

patched = 0
for pub in sorted(set(targets)):
    if relax_file(pub):
        patched += 1
# 校验：放宽后的 environment 必须能过 3.19，且 fvp 仍要求 vppi >=6.3
for pub in sorted(set(targets)):
    text = pub.read_text(encoding="utf-8")
    m = env_re.search(text)
    if m and needs_relax(m.group(0)):
        print(f"ERROR: still too new after relax: {pub.parent.name}", file=sys.stderr)
        sys.exit(1)
    if pub.parent.name.startswith("fvp-") and "video_player_platform_interface: '>=6.3.0'" not in text \
            and 'video_player_platform_interface: ">=6.3.0"' not in text \
            and "video_player_platform_interface: '>=6.3.0'" not in text:
        # also accept unquoted
        if not re.search(r"video_player_platform_interface:\s*['\"]?>=6\.3\.0", text):
            print(f"ERROR: fvp must keep video_player_platform_interface >=6.3.0: {pub}", file=sys.stderr)
            sys.exit(1)
print(f"==> win7 SDK relax ok ({patched} written, {len(set(targets))} checked)")
PY
}

win7=0
if [[ "${KOTV_WIN7:-}" == "1" ]] || flutter --version 2>&1 | grep -qE 'Dart 3\.3\.|Flutter 3\.19'; then
  win7=1
  echo "==> Win7 / Dart 3.3: adapt pubspec before pub get (keep fvp 0.39.0)"
  "$ROOT/scripts/adapt-flutter-win7-sdk.sh"
  # FVP 0.39 编译需要 VideoViewType → platform_interface 6.3.0（官方 Flutter>=3.22，须放宽）。
  _kotv_ensure_hosted_pkg fvp 0.39.0
  _kotv_ensure_hosted_pkg video_player_platform_interface 6.3.0
  _kotv_relax_win7_sdk_constraints
  # 丢掉与主线/高 SDK 冲突的 lock，让 solver 按 root sdk <3.4.0 + overrides 重解。
  if [[ -f "$ROOT/flutter/pubspec.lock" ]]; then
    echo "==> Win7: remove pubspec.lock for clean resolve"
    rm -f "$ROOT/flutter/pubspec.lock"
  fi
else
  fvp_ver=""
  fvp_ver="$(_kotv_python - <<'PY' || true
import json, urllib.request
url = "https://pub.dev/api/packages/fvp"
req = urllib.request.Request(
    url,
    headers={"User-Agent": "KOTV-flutter-pub-get", "Accept": "application/vnd.pub.v2+json"},
)
with urllib.request.urlopen(req, timeout=30) as resp:
    data = json.load(resp)
print(data["latest"]["version"])
PY
)"
  if [[ -n "$fvp_ver" ]]; then
    echo "==> fvp latest from pub.dev: $fvp_ver"
    perl -i -pe "s/^  fvp:\\s*.*/  fvp: ${fvp_ver}/" "$ROOT/flutter/pubspec.yaml"
  else
    echo "WARN: could not resolve latest fvp; using pubspec as-is (fvp: any)" >&2
  fi
fi

cd "$ROOT/flutter"
# pubspec.lock 里的 hosted.url 会盖过 PUB_HOSTED_URL；CI/回退官方源时改写。
if [[ "${PUB_HOSTED_URL:-}" == "https://pub.dev" && -f pubspec.lock ]]; then
  if grep -q 'pub.flutter-io.cn' pubspec.lock 2>/dev/null; then
    echo "==> rewrite pubspec.lock hosted url → pub.dev"
    tmp="$(mktemp)"
    sed 's|https://pub.flutter-io.cn|https://pub.dev|g' pubspec.lock >"$tmp"
    mv "$tmp" pubspec.lock
  fi
fi
if ! flutter pub get "$@"; then
  if [[ "$win7" == "1" ]]; then
    echo "==> Win7 pub get failed; re-prefetch + relax and retry" >&2
    _kotv_ensure_hosted_pkg fvp 0.39.0
    _kotv_ensure_hosted_pkg video_player_platform_interface 6.3.0
    _kotv_relax_win7_sdk_constraints
    flutter pub get "$@"
  elif [[ "${PUB_HOSTED_URL:-}" == *"flutter-io.cn"* ]]; then
    echo "WARN: pub get failed on $PUB_HOSTED_URL; retry pub.dev" >&2
    export PUB_HOSTED_URL=https://pub.dev
    export FLUTTER_STORAGE_BASE_URL="${FLUTTER_STORAGE_BASE_URL:-https://storage.googleapis.com}"
    if [[ -f pubspec.lock ]] && grep -q 'pub.flutter-io.cn' pubspec.lock 2>/dev/null; then
      tmp="$(mktemp)"
      sed 's|https://pub.flutter-io.cn|https://pub.dev|g' pubspec.lock >"$tmp"
      mv "$tmp" pubspec.lock
    fi
    flutter pub get "$@"
  else
    exit 1
  fi
fi
if [[ "$win7" == "1" ]]; then
  # pub get 可能又解压了官方 environment；再放宽并校验一次。
  _kotv_relax_win7_sdk_constraints
else
  # 避免 committed pubspec.lock 把 any 钉在旧版；已写成精确版本时这步是 no-op。
  flutter pub upgrade fvp
fi
# media_kit _setPropertyFlag 1 字节 Bool 传 MPV_FORMAT_FLAG(int)：Windows 上 play() 变 pause。
# 两条线（主线 / Win7）media_kit 都是 1.2.6，同一补丁；失败即中止，禁止带 bug 出包。
chmod +x "$ROOT/scripts/patch-media-kit.sh"
"$ROOT/scripts/patch-media-kit.sh"
