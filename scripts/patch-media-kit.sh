#!/usr/bin/env bash
# 给 pub-cache 里的 media_kit 打补丁：_setPropertyFlag 用 1 字节 Bool 承载 MPV_FORMAT_FLAG。
#
# mpv 的 MPV_FORMAT_FLAG 是 int（4 字节），bool_set 取 !!flag；media_kit 只 calloc<Bool>(1)，
# 高 3 字节是堆上脏数据。Windows（CoTaskMemAlloc）常非零 → play() 写 pause=false 被 mpv
# 读成 pause=true，表现为「播放中、缓冲在涨、time-pos 不动，点一下暂停才起播」（Win7 实锤，
# kotv-mpv.log：[dart] play 后紧跟 Set property: pause=true）。macOS/Linux calloc 通常整块清零
# 所以不复现。pub.dev 1.2.6 与上游 main 均未修，故在 flutter pub get 之后打补丁。
#
# 另外删掉 media_kit 写死的 network-timeout=5。安卓播放器不设这个选项。
# 5 秒会被 lavf 当成读超时：下一段超过 5 秒没有新字节，已经进缓存的那段播完就停。
#
# 删掉 media_kit 写死的 cache-on-disk=yes。该缓存文件只追加，媒体关掉才删除。
# 直播开播不会改这个选项；点播需要磁盘缓存时由应用在开播前写成 yes。
#
# fvp 的 dispose 在删除播放器前等待视频尺寸。尺寸 Completer 被换掉后可能永远等不到，
# mdkPlayerAPI_delete 不执行，上一集的包缓存就留在进程里。补丁让释放纹理时不等尺寸，并等待删除完成。
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

changed = False

if FIXED in text:
    print(f"ok media_kit ({version}) already patched: _setPropertyFlag uses Int32")
elif BUGGY not in text:
    print(
        f"ERROR: media_kit ({version}) _setPropertyFlag snippet not found; "
        "upstream changed — update scripts/patch-media-kit.sh",
        file=sys.stderr,
    )
    sys.exit(1)
elif text.count(BUGGY) != 1:
    print(f"ERROR: expected exactly one occurrence of buggy snippet, got {text.count(BUGGY)}", file=sys.stderr)
    sys.exit(1)
else:
    text = text.replace(BUGGY, FIXED, 1)
    changed = True
    print(f"patched media_kit ({version}): _setPropertyFlag Bool(1 byte) -> Int32")

# media_kit 写死 network-timeout=5。安卓不设这个选项，这里直接删掉这行。
TIMEOUT = "        'network-timeout': '5',\n"
NOTE = "      // network-timeout = 5\n"
if NOTE in text:
    text = text.replace(NOTE, "", 1)
    changed = True
    print(f"patched media_kit ({version}): removed network-timeout comment")
if TIMEOUT in text:
    if text.count(TIMEOUT) != 1:
        print(
            f"ERROR: expected exactly one network-timeout assignment, got {text.count(TIMEOUT)}",
            file=sys.stderr,
        )
        sys.exit(1)
    text = text.replace(TIMEOUT, "", 1)
    changed = True
    print(f"patched media_kit ({version}): removed network-timeout=5")
elif "'network-timeout'" in text:
    print(
        f"ERROR: media_kit ({version}) network-timeout present but not the known '5' line; "
        "upstream changed — update scripts/patch-media-kit.sh",
        file=sys.stderr,
    )
    sys.exit(1)
else:
    print(f"ok media_kit ({version}) already patched: network-timeout unset")

# cache-on-disk=yes：只追加的缓存文件，关掉媒体才删除。默认不要打开。
DISK = "        'cache-on-disk': 'yes',\n"
if DISK in text:
    if text.count(DISK) != 1:
        print(
            f"ERROR: expected exactly one cache-on-disk=yes, got {text.count(DISK)}",
            file=sys.stderr,
        )
        sys.exit(1)
    text = text.replace(DISK, "", 1)
    changed = True
    print(f"patched media_kit ({version}): removed cache-on-disk=yes")
elif "'cache-on-disk'" in text:
    print(
        f"ERROR: media_kit ({version}) cache-on-disk present but not the known yes line; "
        "upstream changed — update scripts/patch-media-kit.sh",
        file=sys.stderr,
    )
    sys.exit(1)
else:
    print(f"ok media_kit ({version}) already patched: cache-on-disk unset")

if changed:
    target.write_text(text, encoding="utf-8")

check = target.read_text(encoding="utf-8")
if FIXED not in check or BUGGY in check:
    print("ERROR: _setPropertyFlag patch verification failed", file=sys.stderr)
    sys.exit(1)
if "'network-timeout'" in check:
    print("ERROR: network-timeout still present after patch", file=sys.stderr)
    sys.exit(1)
if "'cache-on-disk'" in check:
    print("ERROR: cache-on-disk still present after patch", file=sys.stderr)
    sys.exit(1)
print(f"ok media_kit ({version}) patches applied ({target})")

# fvp：width/height <= 0 时不要等视频尺寸，并等播放器真正删掉。
fvp_root = None
fvp_version = "?"
for pkg in data.get("packages", []):
    if pkg.get("name") != "fvp":
        continue
    uri = pkg.get("rootUri") or ""
    if uri.startswith("file:"):
        fvp_root = pathlib.Path(url2pathname(urlparse(uri).path))
    else:
        fvp_root = (cfg.parent / uri).resolve()
    fvp_version = fvp_root.name
    break

if fvp_root is None:
    print("fvp not in package_config.json; skip fvp patch")
    sys.exit(0)

player_dart = fvp_root / "lib" / "src" / "player.dart"
mdk_dart = fvp_root / "lib" / "src" / "video_player_mdk.dart"
if not player_dart.is_file() or not mdk_dart.is_file():
    print(f"ERROR: fvp sources missing under {fvp_root}", file=sys.stderr)
    sys.exit(1)

DISPOSE_OLD = """  /// Release resources
  void dispose() async {
    if (_pp == nullptr) {
      textureId.dispose();
      return;
    }
    // await: ensure no player ref in fvp plugin before mdkPlayerAPI_delete() in dart
    await updateTexture(width: -1);
    state = PlaybackState.stopped;"""
DISPOSE_NEW = """  /// Release resources
  Future<void> dispose() async {
    if (_pp == nullptr) {
      textureId.dispose();
      return;
    }
    // KOTV patch (scripts/patch-media-kit.sh): stop before delete so the demux
    // packet cache goes away with the player.
    state = PlaybackState.stopped;
    // await: ensure no player ref in fvp plugin before mdkPlayerAPI_delete() in dart
    await updateTexture(width: -1);"""
SIZE_WAIT_OLD = """      textureId.value = null;
    }
    final size = await _videoSize.future;"""
SIZE_WAIT_NEW = """      textureId.value = null;
    }
    // KOTV patch (scripts/patch-media-kit.sh): releasing the texture must not wait
    // for a video size. dispose passes width -1; a replaced _videoSize completer
    // would otherwise never finish and mdkPlayerAPI_delete would not run.
    if ((width != null && width <= 0) || (height != null && height <= 0)) {
      return -1;
    }
    final size = await _videoSize.future;"""
# 0.39 在删播放器前先清 platform view；Win7 的 0.37.3 没有这一行。
AWAIT_PAIRS = (
    (
        """    _platformViewParams.remove(playerId);
    _players.remove(playerId)?.dispose();""",
        """    _platformViewParams.remove(playerId);
    await _players.remove(playerId)?.dispose();""",
    ),
    (
        """  Future<void> dispose(int playerId) async {
    _players.remove(playerId)?.dispose();
  }""",
        """  Future<void> dispose(int playerId) async {
    await _players.remove(playerId)?.dispose();
  }""",
    ),
)
# Player.dispose 改成 Future 后，子类 MdkVideoPlayer.dispose 仍是 void 就编不过。
SUB_DISPOSE_OLD = """  @override
  void dispose() {
    streamCtl.close();
    _initialized = false;
    super.dispose();
  }"""
SUB_DISPOSE_NEW = """  @override
  Future<void> dispose() async {
    streamCtl.close();
    _initialized = false;
    await super.dispose();
  }"""

player_text = player_dart.read_text(encoding="utf-8")
mdk_text = mdk_dart.read_text(encoding="utf-8")
fvp_changed = False

def _once(label, blob, old, new):
    return _one_of(label, blob, ((old, new),))

def _one_of(label, blob, pairs):
    global fvp_changed
    for _old, new in pairs:
        if new in blob:
            print(f"ok fvp ({fvp_version}) already patched: {label}")
            return blob
    for old, new in pairs:
        n = blob.count(old)
        if n == 1:
            fvp_changed = True
            print(f"patched fvp ({fvp_version}): {label}")
            return blob.replace(old, new, 1)
        if n > 1:
            print(
                f"ERROR: fvp ({fvp_version}) {label} snippet count {n}; "
                "upstream changed — update scripts/patch-media-kit.sh",
                file=sys.stderr,
            )
            sys.exit(1)
    print(
        f"ERROR: fvp ({fvp_version}) {label} snippet count 0; "
        "upstream changed — update scripts/patch-media-kit.sh",
        file=sys.stderr,
    )
    sys.exit(1)

player_text = _once("dispose stops before delete", player_text, DISPOSE_OLD, DISPOSE_NEW)
player_text = _once("updateTexture release does not wait for size", player_text, SIZE_WAIT_OLD, SIZE_WAIT_NEW)
mdk_text = _one_of("platform dispose awaits player delete", mdk_text, AWAIT_PAIRS)
mdk_text = _once("MdkVideoPlayer.dispose returns Future", mdk_text, SUB_DISPOSE_OLD, SUB_DISPOSE_NEW)

if fvp_changed:
    player_dart.write_text(player_text, encoding="utf-8")
    mdk_dart.write_text(mdk_text, encoding="utf-8")

if "state = PlaybackState.stopped;" not in player_dart.read_text(encoding="utf-8").split("Future<void> dispose", 1)[-1][:500]:
    print("ERROR: fvp dispose patch verification failed", file=sys.stderr)
    sys.exit(1)
if "width <= 0" not in player_dart.read_text(encoding="utf-8"):
    print("ERROR: fvp updateTexture patch verification failed", file=sys.stderr)
    sys.exit(1)
mdk_check = mdk_dart.read_text(encoding="utf-8")
if "await _players.remove(playerId)?.dispose();" not in mdk_check:
    print("ERROR: fvp platform dispose patch verification failed", file=sys.stderr)
    sys.exit(1)
if "await super.dispose();" not in mdk_check:
    print("ERROR: fvp MdkVideoPlayer.dispose patch verification failed", file=sys.stderr)
    sys.exit(1)
print(f"ok fvp ({fvp_version}) patches applied ({player_dart})")
PY
