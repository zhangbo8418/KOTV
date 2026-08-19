#!/usr/bin/env bash
# media_kit_libs_android_video 在配置阶段从 GitHub 拉 libmpv jar。
# CI 偶发 504 会整包失败；给下载加重试，并尽量预拉到 Gradle 缓存目录。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG_CFG="$ROOT/flutter/.dart_tool/package_config.json"
[[ -f "$PKG_CFG" ]] || { echo "missing $PKG_CFG (run flutter pub get first)" >&2; exit 1; }

python3 - "$PKG_CFG" <<'PY'
import json, pathlib, re, sys

cfg = pathlib.Path(sys.argv[1])
data = json.loads(cfg.read_text(encoding="utf-8"))
gradle = None
for pkg in data.get("packages", []):
    if pkg.get("name") != "media_kit_libs_android_video":
        continue
    root_uri = pkg.get("rootUri") or ""
    if root_uri.startswith("file://"):
        root = pathlib.Path(root_uri[7:])
    elif root_uri.startswith("../") or root_uri.startswith("./"):
        root = (cfg.parent / root_uri).resolve()
    else:
        continue
    cand = root / "android" / "build.gradle"
    if cand.is_file():
        gradle = cand
    break

if gradle is None:
    print("skip: media_kit_libs_android_video android/build.gradle not found")
    sys.exit(0)

text = gradle.read_text(encoding="utf-8")
orig = text
helper = '''
// KOTV-PATCH: retry GitHub 5xx when fetching libmpv jars
def kotvDownloadWithRetry(String url, File dest) {
    dest.parentFile.mkdirs()
    Exception last = null
    for (int i = 0; i < 8; i++) {
        try {
            if (dest.exists()) dest.delete()
            dest.withOutputStream { os ->
                def conn = new URL(url).openConnection()
                conn.setConnectTimeout(30000)
                conn.setReadTimeout(120000)
                conn.setInstanceFollowRedirects(true)
                os << conn.getInputStream()
            }
            if (dest.length() > 0) return
            last = new IOException("empty download: " + url)
        } catch (Exception e) {
            last = e
            if (dest.exists()) dest.delete()
            println "KOTV: download retry " + (i + 1) + "/8 for " + url + ": " + e.message
            Thread.sleep(2000L * (i + 1))
        }
    }
    throw last
}

'''
if "def kotvDownloadWithRetry" not in text:
    # 插到第一个非 import / 空行之后、buildscript/group 之前。
    m = re.search(r"(?m)^(group |buildscript |apply plugin)", text)
    if m:
        text = text[: m.start()] + helper + text[m.start() :]
    else:
        text = helper + text

text, n = re.subn(
    r"(\w+)\.withOutputStream\s*\{\s*os\s*->\s*os\s*<<\s*new URL\(([^)]+)\)\.openStream\(\)\s*\}",
    r"kotvDownloadWithRetry(\2 as String, \1)",
    text,
)
if text != orig:
    gradle.write_text(text, encoding="utf-8")
    print(f"patched media_kit jar download retry ({n} site(s)): {gradle}")
else:
    print(f"media_kit jar download already patched: {gradle}")
PY

# 预拉到 Flutter 重映射后的 buildDir，命中 MD5 即可跳过 GitHub。
CACHE_DIR="$ROOT/flutter/build/media_kit_libs_android_video/v1.1.7"
mkdir -p "$CACHE_DIR"
BASE="https://github.com/media-kit/libmpv-android-video-build/releases/download/v1.1.7"
prefetch() {
  local name="$1"
  local dest="$CACHE_DIR/$name"
  if [[ -s "$dest" ]]; then
    echo "prefetch skip (exists): $dest"
    return 0
  fi
  echo "prefetch $name"
  curl -fsSL --retry 8 --retry-all-errors --retry-delay 2 \
    -o "$dest.part" "$BASE/$name"
  mv -f "$dest.part" "$dest"
}
prefetch "default-arm64-v8a.jar"
prefetch "default-armeabi-v7a.jar"
prefetch "default-x86_64.jar"
prefetch "default-x86.jar"
echo "prefetch done: $CACHE_DIR"
