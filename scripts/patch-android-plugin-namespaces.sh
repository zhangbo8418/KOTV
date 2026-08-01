#!/usr/bin/env bash
# 给 pub-cache 里缺 namespace 的 Android 插件补上 namespace（AGP 8+ 必需）。
# 主要修 fijkplayer 等停更插件。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG_CFG="$ROOT/flutter/.dart_tool/package_config.json"
[[ -f "$PKG_CFG" ]] || { echo "missing $PKG_CFG (run flutter pub get first)" >&2; exit 1; }

python3 - "$PKG_CFG" <<'PY'
import json, pathlib, re, sys

cfg = pathlib.Path(sys.argv[1])
data = json.loads(cfg.read_text(encoding="utf-8"))
patched = 0
for pkg in data.get("packages", []):
    root_uri = pkg.get("rootUri") or ""
    if root_uri.startswith("file://"):
        root = pathlib.Path(root_uri[7:])
    elif root_uri.startswith("../") or root_uri.startswith("./"):
        root = (cfg.parent / root_uri).resolve()
    else:
        continue
    gradle = root / "android" / "build.gradle"
    if not gradle.is_file():
        continue
    text = gradle.read_text(encoding="utf-8")
    if re.search(r"(?m)^\s*namespace\s+", text):
        continue
    manifest = root / "android" / "src" / "main" / "AndroidManifest.xml"
    ns = None
    if manifest.is_file():
        m = re.search(r'package\s*=\s*"([^"]+)"', manifest.read_text(encoding="utf-8"))
        if m:
            ns = m.group(1)
    if not ns:
        ns = f"com.legacy.{pkg['name'].replace('-', '_')}"
    # 插到第一个 android { 后
    new, n = re.subn(
        r"(android\s*\{)",
        rf'\1\n    namespace "{ns}"',
        text,
        count=1,
    )
    if n == 0:
        continue
    gradle.write_text(new, encoding="utf-8")
    print(f"patched namespace {pkg['name']} -> {ns}")
    patched += 1
print(f"done: patched {patched} plugin(s)")
PY
