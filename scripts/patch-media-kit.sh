#!/usr/bin/env bash
# 给 pub-cache 里的 media_kit 打补丁：_setPropertyFlag 用 1 字节 Bool 承载 MPV_FORMAT_FLAG。
#
# mpv 的 MPV_FORMAT_FLAG 是 int（4 字节），bool_set 取 !!flag；media_kit 只 calloc<Bool>(1)，
# 高 3 字节是堆上脏数据。Windows（CoTaskMemAlloc）常非零 → play() 写 pause=false 被 mpv
# 读成 pause=true，表现为「播放中、缓冲在涨、time-pos 不动，点一下暂停才起播」（Win7 实锤，
# kotv-mpv.log：[dart] play 后紧跟 Set property: pause=true）。macOS/Linux calloc 通常整块清零
# 所以不复现。pub.dev 1.2.6 与上游 main 均未修，故在 flutter pub get 之后打补丁。
#
# 幂等：已打过直接通过；找不到目标片段且未打过 → 失败（禁止带着 bug 出包）。
# 用法：scripts/patch-media-kit.sh   （flutter-pub-get.sh 末尾自动调用）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG_CFG="$ROOT/flutter/.dart_tool/package_config.json"
[[ -f "$PKG_CFG" ]] || { echo "missing $PKG_CFG (run flutter pub get first)" >&2; exit 1; }

_kotv_python() {
  if command -v python3 >/dev/null 2>&1; then
    python3 "$@"
  elif command -v python >/dev/null 2>&1; then
    python "$@"
  elif command -v py >/dev/null 2>&1; then
    py -3 "$@"
  else
    echo "ERROR: python not found (needed by patch-media-kit.sh)" >&2
    return 1
  fi
}

_kotv_python - "$PKG_CFG" <<'PY'
import json, pathlib, sys
from urllib.parse import urlparse
from urllib.request import url2pathname

cfg = pathlib.Path(sys.argv[1])
data = json.loads(cfg.read_text(encoding="utf-8"))

root = None
version = "?"
for pkg in data.get("packages", []):
    if pkg.get("name") != "media_kit":
        continue
    uri = pkg.get("rootUri") or ""
    if uri.startswith("file:"):
        root = pathlib.Path(url2pathname(urlparse(uri).path))
    else:
        root = (cfg.parent / uri).resolve()
    version = root.name
    break

if root is None:
    print("media_kit not in package_config.json; nothing to patch")
    sys.exit(0)

target = root / "lib" / "src" / "player" / "native" / "player" / "real.dart"
if not target.is_file():
    print(f"ERROR: {target} missing", file=sys.stderr)
    sys.exit(1)

text = target.read_text(encoding="utf-8")

BUGGY = "final ptr = calloc<Bool>(1)..value = value;"
FIXED = (
    "// KOTV patch (scripts/patch-media-kit.sh): MPV_FORMAT_FLAG is a C int (4 bytes);\n"
    "    // a 1-byte Bool leaves 3 bytes of heap garbage that mpv reads via !!flag.\n"
    "    final ptr = calloc<Int32>(1)..value = value ? 1 : 0;"
)

if FIXED in text:
    print(f"ok media_kit ({version}) already patched: _setPropertyFlag uses Int32")
    sys.exit(0)

if BUGGY not in text:
    print(
        f"ERROR: media_kit ({version}) _setPropertyFlag snippet not found; "
        "upstream changed — update scripts/patch-media-kit.sh",
        file=sys.stderr,
    )
    sys.exit(1)

if text.count(BUGGY) != 1:
    print(f"ERROR: expected exactly one occurrence of buggy snippet, got {text.count(BUGGY)}", file=sys.stderr)
    sys.exit(1)

target.write_text(text.replace(BUGGY, FIXED), encoding="utf-8")

check = target.read_text(encoding="utf-8")
if FIXED not in check or BUGGY in check:
    print("ERROR: patch verification failed", file=sys.stderr)
    sys.exit(1)
print(f"patched media_kit ({version}): _setPropertyFlag Bool(1 byte) -> Int32 ({target})")
PY
