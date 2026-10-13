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
# FvpVideoView.surfaceDestroyed 上游会 release()→nativeSetSurface(null)。全屏改
# LayoutParams 常触发临时 surfaceDestroyed，整表抹掉 players 后易定格/崩。改成空
# 实现（与 KotvExo SurfaceView 同语义）；永久卸面仍走 dispose()→release()。
#
# prepare 失败写入 _players[-hashCode] 时若覆盖同 key，旧 player 会泄漏；改为先 dispose 再挂新的。
#
# Windows 插件原来每帧 CopyResource 进同一张 shared 纹理。Flutter 只在 handle 变化时
# 才放开它，拷贝没有结束信号。补丁改成三张纹理，renderVideo 直接画进 Flutter 没拿着的
# 那张，不再做整帧拷贝。
#
# reader.buffering 把毫秒的 position 装进了 Duration(microseconds:)。改成毫秒。
# getPosition 组装缓冲区间时也用毫秒。
#
# Windows 插件在 prepare 之前建一个 D3D11 设备，交给 d3d11.device，并设 d3d11.copy=0
# （均为 mdk Global-Options 文档项）。上游 fvp 会写 d3d11.sync.cpu，wiki/mdk.dll 均无此
# 全局选项（仅有环境变量 D3D11_SYNC_CPU 与文档项 d3d11.sync.kmt），故删掉那一行。
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
import json, pathlib, re, sys
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
controller_dart = fvp_root / "lib" / "src" / "controller.dart"
if not player_dart.is_file() or not mdk_dart.is_file() or not controller_dart.is_file():
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
controller_text = controller_dart.read_text(encoding="utf-8")
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
# reader.buffering 的 position 是毫秒。getPosition 也按毫秒组装区间。
# 片段带上 reader.buffering，避免和 getPosition 里已是毫秒的区间撞车。
BUF_RANGE_OLD = """      if (ev.category == "reader.buffering") {
        final pos = position;
        final bufLen = buffered();
        streamCtl.add(
          VideoEvent(
            eventType: VideoEventType.bufferingUpdate,
            buffered: [
              DurationRange(
                Duration(microseconds: pos),
                Duration(milliseconds: pos + bufLen),
              ),"""
BUF_RANGE_NEW = """      if (ev.category == "reader.buffering") {
        final pos = position;
        final bufLen = buffered();
        streamCtl.add(
          VideoEvent(
            eventType: VideoEventType.bufferingUpdate,
            buffered: [
              DurationRange(
                Duration(milliseconds: pos),
                Duration(milliseconds: pos + bufLen),
              ),"""
mdk_text = _once("reader.buffering range start is milliseconds", mdk_text, BUF_RANGE_OLD, BUF_RANGE_NEW)

# prepare / 出纹理失败时都写 _players[-hashCode]。同一 key 被覆盖时上一只 player
# 再也 dispose 不到，连播重试/换集会把 mdk 包缓存堆在进程里。
# 助手内部用 failedId 赋值，避免全局替换把助手自己也改成递归调用。
ORPHAN_HELPER = """
  /// KOTV patch: keep at most one failed player under [-hashCode]; dispose the previous.
  Future<void> _storeFailedPlayer(MdkVideoPlayer player) async {
    final failedId = -hashCode;
    final prev = _players.remove(failedId);
    _players[failedId] = player;
    if (prev != null && !identical(prev, player)) {
      await prev.dispose();
    }
  }
"""
# 清掉旧版误补丁（递归助手、重复注释、误挂的 @override）。
mdk_text, n_broken = re.subn(
    r"  @override\n\n  /// KOTV patch: keep at most one failed player[^\n]*\n"
    r"(?:  /// KOTV patch: keep at most one failed player[^\n]*\n)?"
    r"  Future<void> _storeFailedPlayer\(MdkVideoPlayer player\) async \{\n"
    r"    final prev = _players\.remove\(-hashCode\);\n"
    r"    await _storeFailedPlayer\(player\);\n"
    r"    if \(prev != null && !identical\(prev, player\)\) \{\n"
    r"      await prev\.dispose\(\);\n"
    r"    \}\n"
    r"  \}\n+",
    ORPHAN_HELPER.lstrip("\n") + "\n",
    mdk_text,
    count=1,
)
if n_broken:
    fvp_changed = True
    print(f"patched fvp ({fvp_version}): fix recursive failed-player helper")

mdk_text, n_dup = re.subn(
    r"  @override\n\n  /// KOTV patch: keep at most one failed player[^\n]*\n"
    r"  /// KOTV patch: keep at most one failed player[^\n]*\n"
    r"  Future<void> _storeFailedPlayer\(MdkVideoPlayer player\) async \{\n"
    r"    final failedId = -hashCode;\n"
    r"    final prev = _players\.remove\(failedId\);\n"
    r"    _players\[failedId\] = player;\n"
    r"    if \(prev != null && !identical\(prev, player\)\) \{\n"
    r"      await prev\.dispose\(\);\n"
    r"    \}\n"
    r"  \}\n+",
    ORPHAN_HELPER.lstrip("\n") + "\n",
    mdk_text,
    count=1,
)
if n_dup:
    fvp_changed = True
    print(f"patched fvp ({fvp_version}): clean failed-player helper placement")

if "final failedId = -hashCode;" not in mdk_text:
    anchor = "  Future<void> dispose(int playerId) async {"
    if anchor not in mdk_text:
        print("ERROR: fvp platform dispose anchor missing for orphan helper", file=sys.stderr)
        sys.exit(1)
    mdk_text = mdk_text.replace(anchor, ORPHAN_HELPER + "\n" + anchor, 1)
    fvp_changed = True
    print(f"patched fvp ({fvp_version}): failed-player orphan helper")
else:
    print(f"ok fvp ({fvp_version}) already patched: failed-player orphan helper")

orphan_n = mdk_text.count("_players[-hashCode] = player;")
if orphan_n:
    mdk_text = mdk_text.replace(
        "_players[-hashCode] = player;",
        "await _storeFailedPlayer(player);",
    )
    fvp_changed = True
    print(f"patched fvp ({fvp_version}): store failed players via helper ({orphan_n})")
elif "await _storeFailedPlayer(player);" in mdk_text:
    print(f"ok fvp ({fvp_version}) already patched: store failed players via helper")
else:
    print(
        f"ERROR: fvp ({fvp_version}) failed-player store sites missing",
        file=sys.stderr,
    )
    sys.exit(1)
helper_body = mdk_text.split("final failedId = -hashCode;", 1)[-1].split(
    "Future<void> dispose(int playerId)", 1
)[0]
if "await _storeFailedPlayer(player);" in helper_body:
    print("ERROR: failed-player helper still calls itself", file=sys.stderr)
    sys.exit(1)
if mdk_text.count("await _storeFailedPlayer(player);") < 3:
    print("ERROR: expected at least 3 failed-player store call sites", file=sys.stderr)
    sys.exit(1)

# 上游可能仍写 d3d11.sync.cpu；缓存里也可能已被旧补丁删掉（注释文案会变）。
if "setGlobalOption('d3d11.sync.cpu'" in mdk_text:
    mdk_text = _once(
        "remove undocumented d3d11.sync.cpu",
        mdk_text,
        "    mdk.setGlobalOption('d3d11.sync.cpu', 1);\n",
        "    // KOTV patch: upstream fvp sets d3d11.sync.cpu, but mdk Global-Options has\n"
        "    // no such key (only env D3D11_SYNC_CPU / d3d11.sync.kmt). Drop it; Windows\n"
        "    // plugin publishes d3d11.device + d3d11.copy=0 instead.\n",
    )
else:
    print(f"ok fvp ({fvp_version}) already patched: remove undocumented d3d11.sync.cpu")

# create：player 属性写完后显式 setBufferRange(min:0, max:0)。
# max 必须显式 >=0：Dart 默认 max=-1 会把 max/drop 打回默认值。
# 不用 lowLatency（会把 analyzeduration 砍到 100ms，伪扩展名 prepare 易失败）。
BUF_RANGE_CREATE_OLD = """    _playerOpts?.forEach((key, value) {
      player.setProperty(key, value);
    });
    // KOTV: mdk default minMs=1000 → ~1fps on queue underrun. Call the API
    // (same as lowLatency) without shrinking analyzeduration.
    if (_lowLatency <= 0) {
      player.setBufferRange(min: 0);
    }

    if (_decoders != null) {
"""
BUF_RANGE_CREATE_NEW = """    _playerOpts?.forEach((key, value) {
      player.setProperty(key, value);
    });
    // KOTV: min=0 decode ASAP; max=0 → INT64_MAX. Never pass max=-1.
    if (_lowLatency <= 0) {
      player.setBufferRange(min: 0, max: 0);
    }

    if (_decoders != null) {
"""
if "player.setBufferRange(min: 0, max: 0);" in mdk_text:
    print(f"ok fvp ({fvp_version}) already patched: setBufferRange min=0 max=0 after player opts")
elif "player.setBufferRange(min: 0);" in mdk_text and "_lowLatency <= 0" in mdk_text:
    mdk_text = _once(
        "setBufferRange min=0 max=0 after player opts",
        mdk_text,
        BUF_RANGE_CREATE_OLD,
        BUF_RANGE_CREATE_NEW,
    )
else:
    mdk_text = _once(
        "setBufferRange min=0 max=0 after player opts",
        mdk_text,
        """    _playerOpts?.forEach((key, value) {
      player.setProperty(key, value);
    });

    if (_decoders != null) {
""",
        BUF_RANGE_CREATE_NEW,
    )

# create：X-KOTV-Prepare-Ms → prepare(startPosition)；勿发往 CDN。
# 对齐 Mac MPV Media(start:) / mdk prepare(ms)；避免 prepare(0)+seekTo 触发安卓 AMediaCodec FLUSHING。
PREPARE_START_OLD = """    if (dataSource.httpHeaders.isNotEmpty) {
      String headers = '';
      dataSource.httpHeaders.forEach((key, value) {
        headers += '$key: $value\\r\\n';
      });
      player.setProperty('avio.headers', headers);
    }
    player.media = uri;
    int ret = await player.prepare(); // required!
"""
PREPARE_START_NEW = """    // KOTV: X-KOTV-Prepare-Ms → prepare(ms); strip before avio.headers (CDN).
    // Same idea as Mac MPV Media(start:) / mdk prepare(startPosition).
    var prepareMs = 0;
    if (dataSource.httpHeaders.isNotEmpty) {
      String headers = '';
      dataSource.httpHeaders.forEach((key, value) {
        if (key == 'X-KOTV-Prepare-Ms') {
          prepareMs = int.tryParse(value) ?? 0;
          return;
        }
        headers += '$key: $value\\r\\n';
      });
      if (headers.isNotEmpty) {
        player.setProperty('avio.headers', headers);
      }
    }
    player.media = uri;
    int ret = await player.prepare(position: prepareMs); // required!
"""
if "X-KOTV-Prepare-Ms" in mdk_text:
    print(f"ok fvp ({fvp_version}) already patched: prepare(startPosition) via X-KOTV-Prepare-Ms")
else:
    mdk_text = _once(
        "prepare(startPosition) via X-KOTV-Prepare-Ms",
        mdk_text,
        PREPARE_START_OLD,
        PREPARE_START_NEW,
    )

# lowLatency 分支：setBufferRange(min:0) 省略 max → Dart 默认 max=-1 会把 max/drop
# 打回默认，并可能让后续路径回到 minMs=1000（ADB timediff≈1000ms）。
LOW_LAT_BUF_OLD = """      if (_lowLatency > 1) {
        player.setBufferRange(min: 0, max: 1000, drop: true);
      } else {
        player.setBufferRange(min: 0);
      }
"""
LOW_LAT_BUF_NEW = """      if (_lowLatency > 1) {
        player.setBufferRange(min: 0, max: 1000, drop: true);
      } else {
        // KOTV: never omit max (default -1 resets max/drop; undoes min=0).
        player.setBufferRange(min: 0, max: 0);
      }
"""
if "never omit max (default -1 resets max/drop" in mdk_text:
    print(f"ok fvp ({fvp_version}) already patched: lowLatency setBufferRange max=0")
elif "player.setBufferRange(min: 0);" in mdk_text:
    mdk_text = _once(
        "lowLatency setBufferRange max=0",
        mdk_text,
        LOW_LAT_BUF_OLD,
        LOW_LAT_BUF_NEW,
    )
else:
    print(f"ok fvp ({fvp_version}): no bare setBufferRange(min: 0) in lowLatency branch")

# Windows：三张 shared 纹理轮换。renderVideo 画进 Flutter 没拿着的那张，取纹理时只交 handle。
WIN_PLUGIN = fvp_root / "windows" / "fvp_plugin.cpp"
WIN_COPY_OLD = """        D3D11_TEXTURE2D_DESC desc;
        rt->GetDesc(&desc);
        desc.MiscFlags |= D3D11_RESOURCE_MISC_SHARED;
        MS_ENSURE(dev->CreateTexture2D(&desc, nullptr, &tex));

        ComPtr<IDXGIResource> res;
        MS_ENSURE(tex.As(&res));
        HANDLE shared_handle = nullptr;
        MS_ENSURE(res->GetSharedHandle(&shared_handle));
        flt_surface_desc->struct_size = sizeof(FlutterDesktopGpuSurfaceDescriptor);
        flt_surface_desc->handle = shared_handle;// tex.Get();
        //flt_surface_desc->handle = tex.Get(); // eglbind error
        flt_surface_desc->width = flt_surface_desc->visible_width = desc.Width;
        flt_surface_desc->height = flt_surface_desc->visible_height = desc.Height;
        flt_surface_desc->release_context = nullptr;
        flt_surface_desc->release_callback = [](void* release_context) {};
        //flt_surface_desc->format = kFlutterDesktopPixelFormatBGRA8888;
        flt_tex = make_unique<flutter::TextureVariant>(flutter::GpuSurfaceTexture(
            kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle
            //kFlutterDesktopGpuSurfaceTypeD3d11Texture2D
            , [pflt_surface_desc = flt_surface_desc.get(), this](size_t width, size_t height) {
                //printf("ObtainDescriptorCallback %llux%llu. shared_handle_ %p\\n", width, height, shared_handle_); fflush(nullptr);
                //player.renderVideo(); // stutter
                scoped_lock lock(mtx);
                ctx->CopyResource(tex.Get(), rt.Get());
                ctx->Flush();
                return pflt_surface_desc;
            }));
        textureId = texRegistrar->RegisterTexture(flt_tex.get());


        D3D11RenderAPI ra{};
        ra.rtv = rt.Get();
        setRenderAPI(&ra);
        setVideoSurfaceSize(desc.Width, desc.Height);
        setRenderCallback([this, texRegistrar](void*) {
            scoped_lock lock(mtx);
            renderVideo();
            texRegistrar->MarkTextureFrameAvailable(textureId);
            });"""
WIN_COPY_NEW = """        D3D11_TEXTURE2D_DESC desc;
        rt->GetDesc(&desc);
        desc.MiscFlags |= D3D11_RESOURCE_MISC_SHARED;
        shared_tex[0] = rt;
        MS_ENSURE(dev->CreateTexture2D(&desc, nullptr, &shared_tex[1]));
        MS_ENSURE(dev->CreateTexture2D(&desc, nullptr, &shared_tex[2]));
        for (int i = 0; i < 3; ++i) {
            ComPtr<IDXGIResource> res;
            MS_ENSURE(shared_tex[i].As(&res));
            HANDLE shared_handle = nullptr;
            MS_ENSURE(res->GetSharedHandle(&shared_handle));
            flt_surface_desc[i].struct_size = sizeof(FlutterDesktopGpuSurfaceDescriptor);
            flt_surface_desc[i].handle = shared_handle;
            flt_surface_desc[i].width = flt_surface_desc[i].visible_width = desc.Width;
            flt_surface_desc[i].height = flt_surface_desc[i].visible_height = desc.Height;
            flt_surface_desc[i].release_context = nullptr;
            flt_surface_desc[i].release_callback = [](void*) {};
        }
        flt_tex = make_unique<flutter::TextureVariant>(flutter::GpuSurfaceTexture(
            kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle
            , [this](size_t width, size_t height) {
                scoped_lock lock(mtx);
                previous = held;
                held = presented;
                return &flt_surface_desc[presented];
            }));
        textureId = texRegistrar->RegisterTexture(flt_tex.get());


        D3D11RenderAPI ra{};
        ra.rtv = shared_tex[0].Get();
        setRenderAPI(&ra);
        setVideoSurfaceSize(desc.Width, desc.Height);
        setRenderCallback([this, texRegistrar](void*) {
            scoped_lock lock(mtx);
            // KOTV patch (scripts/patch-media-kit.sh): draw into a texture Flutter
            // is not holding. rtv accepts the texture itself. No CopyResource.
            int i = 0;
            for (int k = 0; k < 3; ++k) {
                if (k != held && k != previous) {
                    i = k;
                    break;
                }
            }
            D3D11RenderAPI frame{};
            frame.rtv = shared_tex[i].Get();
            setRenderAPI(&frame);
            renderVideo();
            presented = i;
            texRegistrar->MarkTextureFrameAvailable(textureId);
            });"""
WIN_MEMBERS_OLD = """    unique_ptr<FlutterDesktopGpuSurfaceDescriptor> flt_surface_desc = make_unique<FlutterDesktopGpuSurfaceDescriptor>();
    ComPtr<ID3D11Texture2D> tex;"""
WIN_MEMBERS_NEW = """    FlutterDesktopGpuSurfaceDescriptor flt_surface_desc[3]{};
    ComPtr<ID3D11Texture2D> shared_tex[3];
    int held = 0;
    int previous = 0;
    int presented = 0;"""

win_text = ""
if not WIN_PLUGIN.is_file():
    print(f"ERROR: fvp windows plugin missing: {WIN_PLUGIN}", file=sys.stderr)
    sys.exit(1)
win_text = WIN_PLUGIN.read_text(encoding="utf-8")
win_text = _once("windows texture is rendered without a copy", win_text, WIN_COPY_OLD, WIN_COPY_NEW)
win_text = _once("windows texture members", win_text, WIN_MEMBERS_OLD, WIN_MEMBERS_NEW)

DEVICE_BODY = """  // KOTV patch (scripts/patch-media-kit.sh): one D3D11 device before prepare.
  // Decoder and Flutter textures share it. d3d11.copy=0 skips the cross-device copy.
  MS_WARN(D3D11CreateDevice(adapter_.Get(), adapter_ ? D3D_DRIVER_TYPE_UNKNOWN : D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, nullptr, 0, D3D11_SDK_VERSION, &dev_, nullptr, &ctx_));
  if (dev_) {
    ComPtr<ID3D10Multithread> mt;
    if (SUCCEEDED(dev_.As(&mt)))
      mt->SetMultithreadProtected(TRUE);
    SetGlobalOption("d3d11.device", static_cast<void*>(dev_.Get()));
    const int d3d_copy = 0;
    SetGlobalOption("d3d11.copy", d3d_copy);
  }
"""
WIN_DEVICE_PAIRS = (
    (
        """FvpPlugin::FvpPlugin(flutter::TextureRegistrar* tr, IDXGIAdapter* adapter)
    : texture_registrar_(tr)
    , adapter_(adapter)
{
  MdkCallbacksStartup();
}""",
        """FvpPlugin::FvpPlugin(flutter::TextureRegistrar* tr, IDXGIAdapter* adapter)
    : texture_registrar_(tr)
    , adapter_(adapter)
{
  MdkCallbacksStartup();
""" + DEVICE_BODY + "}",
    ),
    (
        """FvpPlugin::FvpPlugin(flutter::TextureRegistrar* tr, IDXGIAdapter* adapter)
    : texture_registrar_(tr)
    , adapter_(adapter)
{}""",
        """FvpPlugin::FvpPlugin(flutter::TextureRegistrar* tr, IDXGIAdapter* adapter)
    : texture_registrar_(tr)
    , adapter_(adapter)
{""" + "\n" + DEVICE_BODY + "}",
    ),
)
win_text = _one_of("d3d11 device exists before prepare", win_text, WIN_DEVICE_PAIRS)
win_text = _once(
    "CreateRT reuses the shared d3d11 device",
    win_text,
    """      MS_WARN(D3D11CreateDevice(adapter_.Get(), adapter_ ? D3D_DRIVER_TYPE_UNKNOWN : D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, nullptr, 0, D3D11_SDK_VERSION, &dev_, nullptr, &ctx_));
      if (!dev_) {
          result->Error("device", "create device failed");
          return;
      }
      ComPtr<ID3D10Multithread> mt;
      if (SUCCEEDED(dev_.As(&mt)))
          mt->SetMultithreadProtected(TRUE);""",
    """      // KOTV patch (scripts/patch-media-kit.sh): device is created in the
      // constructor and published as d3d11.device before prepare.
      if (!dev_) {
          result->Error("device", "create device failed");
          return;
      }""",
)

if fvp_changed:
    player_dart.write_text(player_text, encoding="utf-8")
    mdk_dart.write_text(mdk_text, encoding="utf-8")
    controller_dart.write_text(controller_text, encoding="utf-8")
    WIN_PLUGIN.write_text(win_text, encoding="utf-8")

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
buf_at = mdk_check.find('reader.buffering')
buf_chunk = mdk_check[buf_at:buf_at + 700] if buf_at >= 0 else ""
if "Duration(microseconds: pos)" in buf_chunk or "Duration(milliseconds: pos)" not in buf_chunk:
    print("ERROR: fvp reader.buffering still uses microseconds", file=sys.stderr)
    sys.exit(1)
win_check = WIN_PLUGIN.read_text(encoding="utf-8")
if "frame.rtv = shared_tex[i].Get();" not in win_check or "k != held" not in win_check:
    print("ERROR: fvp windows zero-copy texture patch verification failed", file=sys.stderr)
    sys.exit(1)
if "CopyResource(" in win_check:
    print("ERROR: fvp windows plugin still copies the frame", file=sys.stderr)
    sys.exit(1)
if "setGlobalOption('d3d11.sync.cpu'" in mdk_check:
    print("ERROR: fvp still sets undocumented d3d11.sync.cpu", file=sys.stderr)
    sys.exit(1)
if "player.setBufferRange(min: 0, max: 0);" not in mdk_check or "_lowLatency <= 0" not in mdk_check:
    print("ERROR: fvp create missing setBufferRange(min: 0, max: 0) after player opts", file=sys.stderr)
    sys.exit(1)
if "X-KOTV-Prepare-Ms" not in mdk_check or "prepare(position: prepareMs)" not in mdk_check:
    print("ERROR: fvp create missing prepare(startPosition) via X-KOTV-Prepare-Ms", file=sys.stderr)
    sys.exit(1)
if "player.setBufferRange(min: 0);" in mdk_check and "_lowLatency > 1" in mdk_check:
    print("ERROR: fvp lowLatency still has setBufferRange(min: 0) without max", file=sys.stderr)
    sys.exit(1)
if 'SetGlobalOption("d3d11.device"' not in win_check or 'SetGlobalOption("d3d11.copy"' not in win_check:
    print("ERROR: fvp windows plugin does not publish the shared d3d11 device", file=sys.stderr)
    sys.exit(1)
if win_check.count("D3D11CreateDevice(") != 1:
    print("ERROR: fvp windows plugin must create the d3d11 device once", file=sys.stderr)
    sys.exit(1)

# Android FvpVideoView：临时 surfaceDestroyed 勿 release（全屏改尺寸会触发）。
fvp_video_view = (
    fvp_root
    / "android"
    / "src"
    / "main"
    / "java"
    / "com"
    / "mediadevkit"
    / "fvp"
    / "FvpVideoView.java"
)
if not fvp_video_view.is_file():
    print(f"ERROR: missing {fvp_video_view}", file=sys.stderr)
    sys.exit(1)
FVP_SURFACE_DESTROYED_OLD = """    @Override
    public void surfaceDestroyed(SurfaceHolder holder) {
        release();
    }"""
FVP_SURFACE_DESTROYED_NEW = """    @Override
    public void surfaceDestroyed(SurfaceHolder holder) {
        // KOTV patch (scripts/patch-media-kit.sh): fullscreen / LayoutParams
        // changes often destroy the Surface temporarily. Do not release() here
        // (that erases native players and freezes or crashes on rebind).
        // Permanent teardown still goes through dispose() → release().
    }"""
fvv_text = fvp_video_view.read_text(encoding="utf-8")
if FVP_SURFACE_DESTROYED_NEW in fvv_text:
    print(f"ok fvp ({fvp_version}) already patched: FvpVideoView.surfaceDestroyed no-op")
elif FVP_SURFACE_DESTROYED_OLD in fvv_text:
    fvp_video_view.write_text(
        fvv_text.replace(FVP_SURFACE_DESTROYED_OLD, FVP_SURFACE_DESTROYED_NEW, 1),
        encoding="utf-8",
    )
    print(f"patched fvp ({fvp_version}): FvpVideoView.surfaceDestroyed no-op")
else:
    print(
        f"ERROR: fvp ({fvp_version}) FvpVideoView.surfaceDestroyed snippet missing; "
        "upstream changed — update scripts/patch-media-kit.sh",
        file=sys.stderr,
    )
    sys.exit(1)
fvv_check = fvp_video_view.read_text(encoding="utf-8")
if "surfaceDestroyed(SurfaceHolder holder) {\n        release();" in fvv_check:
    print("ERROR: FvpVideoView.surfaceDestroyed still calls release()", file=sys.stderr)
    sys.exit(1)
if "dispose() {\n        surfaceView.getHolder().removeCallback(this);\n        release();" not in fvv_check:
    print("ERROR: FvpVideoView.dispose must still call release()", file=sys.stderr)
    sys.exit(1)

print(f"ok fvp ({fvp_version}) patches applied ({player_dart})")
PY
