import 'dart:async';

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'buffer_budget.dart';
import 'drm_opts.dart';
import 'kotv_platform.dart';
import 'kotv_playback.dart';
import 'kotv_win7_direct.dart';
import 'mpv_opts.dart';
import 'play_format.dart';
import 'play_headers.dart';
import 'player_normalize.dart';
import 'silent_video_guard.dart';
import 'video_eq.dart';

/// 桌面 libmpv 卡死恢复：pause / stop / dispose 分段限时。
/// 页面硬停等待应 ≥ pause+stop+drain+dispose（见 [kotvMpvLeaveTimeout]）。
const kotvMpvPauseAbandon = Duration(seconds: 1);
const kotvMpvStopAbandon = Duration(seconds: 2);
const kotvMpvDisposeAbandon = Duration(seconds: 3);
const kotvMpvDrain = Duration(milliseconds: 250);

/// 离开页 / prepareLeave 等待拆机的上限（含弃僵尸窗口）。
const kotvMpvLeaveTimeout = Duration(seconds: 8);

/// 进行中的桌面 libmpv 拆机；新建 Player 前须等待（避免与僵死 stop/dispose 抢 AO）。
Future<void>? _kotvMpvTeardown;

/// 等待上一次 [kotvDisposeMpvPlayer] 结束（含超时弃等待）。
Future<void> kotvAwaitMpvTeardown() async {
  final t = _kotvMpvTeardown;
  if (t == null) return;
  try {
    await t;
  } catch (_) {}
}

/// 安全释放 libmpv [Player]：pause → stop → 短排空 → dispose，全程登记门闩。
/// 各桌面平台共用 [kotvTeardownPlayback]。分段限时：卡住时弃等待以便再建；
/// 同进程原生线程可能仍存活至进程退出——这是 in-process libmpv 的上限，不是杀进程冒充成功。
Future<void> kotvDisposeMpvPlayer(Player? player) async {
  if (player == null) return;
  final prev = _kotvMpvTeardown;
  late final Future<void> mine;
  mine = () async {
    if (prev != null) {
      try {
        await prev;
      } catch (_) {}
    }
    try {
      await player.pause().timeout(kotvMpvPauseAbandon);
    } catch (_) {}
    await kotvTeardownPlayback(
      stop: () => player.stop(),
      dispose: () => player.dispose(),
      drain: kotvMpvDrain,
      stopTimeout: kotvMpvStopAbandon,
      disposeTimeout: kotvMpvDisposeAbandon,
    );
  }();
  _kotvMpvTeardown = mine;
  try {
    await mine;
  } finally {
    if (identical(_kotvMpvTeardown, mine)) {
      _kotvMpvTeardown = null;
    }
  }
}

/// 按缓冲预算创建 [Player]。点播和直播同一份内存比例。
/// 起播请用 [kotvAcquireMpvPlayer]，勿在拆机未完成时直接调用。
Player kotvCreateMpvPlayer() {
  final budget = KotvBufferBudget.bytes();
  return Player(
    configuration: PlayerConfiguration(
      bufferSize: budget,
    ),
  );
}

/// 异步取得新 Player：先等拆机门闩，再 [kotvCreateMpvPlayer]。详情/直播起播共用。
Future<Player> kotvAcquireMpvPlayer() async {
  await kotvAwaitMpvTeardown();
  return kotvCreateMpvPlayer();
}

String _trackLabel(dynamic t) {
  if (t.title?.isNotEmpty == true) return t.title! as String;
  if (t.language?.isNotEmpty == true) return t.language! as String;
  return t.id as String;
}

KotvTrack _kotvTrackFromMediaKit(dynamic t) {
  final codec = '${t.codec ?? ''}'.trim();
  var label = _trackLabel(t);
  if (codec.isNotEmpty && !label.toLowerCase().contains(codec.toLowerCase())) {
    label = '$label ($codec)';
  }
  return KotvTrack(
    id: '${t.id}',
    label: label,
    language: '${t.language ?? ''}'.trim(),
    codec: codec,
  );
}

/// media_kit / libmpv（桌面 / iOS 等非 Android 原生插件路径）。
class MediaKitPlayback extends KotvPlayback {
  /// [live]=true：构造期就关 cache-pause，并且不打开磁盘缓存。字节上限与点播相同。
  /// [onWin7SoftOnDirect]：直出 Player 已落到软解时回调（须换 D3D11 Player；勿在回调里同步 dispose 本实例）。
  MediaKitPlayback(
    this.player, {
    KotvMpvOpts? opts,
    bool live = false,
    void Function()? onWin7SoftOnDirect,
  })  : _opts = opts ?? const KotvMpvOpts(),
        _live = live,
        _onWin7SoftOnDirect = onWin7SoftOnDirect,
        controller = VideoController(
          player,
          configuration: (opts ?? const KotvMpvOpts()).videoControllerConfiguration(),
        ) {
    _subs.add(player.stream.playing.listen((_) => notifyListeners()));
    // 进度走 positionStream 直通 player.stream.position；勿每帧 notifyListeners。
    _subs.add(player.stream.duration.listen((_) => notifyListeners()));
    _subs.add(player.stream.buffer.listen((_) => notifyListeners()));
    _subs.add(player.stream.buffering.listen((v) {
      _buffering = v;
      if (!v) _speedBps = 0;
      notifyListeners();
    }));
    _subs.add(player.stream.width.listen((w) {
      if (!_acceptSize) return;
      final next = w ?? 0;
      // 无缝切入时可能先推 null/0；勿盖掉仍有效的尺寸（含换集分辨率变化前的过渡）。
      if (next <= 0) return;
      _w = next;
      notifyListeners();
    }));
    _subs.add(player.stream.height.listen((h) {
      if (!_acceptSize) return;
      final next = h ?? 0;
      if (next <= 0) return;
      _h = next;
      notifyListeners();
    }));
    _subs.add(player.stream.volume.listen((_) => notifyListeners()));
    _subs.add(player.stream.rate.listen((_) => notifyListeners()));
    _subs.add(player.stream.completed.listen((done) {
      notifyListeners();
      unawaited(_onPlayerCompleted(done));
    }));
    _subs.add(player.stream.error.listen((msg) {
      unawaited(_maybeRetryHlsAfterError(msg));
    }));
    _subs.add(player.stream.playlist.listen((pl) {
      final q = _queued;
      if (q == null) return;
      // 以当前项 URI 识别已接到下一集（勿写死下标 1）。
      if (_playlistUriAt(pl, pl.index) == q.media.uri) _enterQueued(q);
    }));
    // 网速浮层走 KotvTraffic；勿轮询 demuxer-cache-state（换集/换台重建 demuxer 时易卡音）。
    _optsReady = _prepareOpts();
  }

  int _openSerial = 0;
  int _openGen = 0;
  /// 已排进播放列表的下一集；播到它时由 playlist 下标切成当前集。
  ({String id, String url, Media media})? _queued;
  final _queuedStartCtrl = StreamController<String>.broadcast();
  /// EOF 且无排队项时才向外报 completed；有排队项时由 [_skipToQueued] 接下一集。
  final _completedCtrl = StreamController<bool>.broadcast();
  String _mpvUserAgent = '';
  String _mpvReferer = '';

  /// 每次打开都写。没有则写空，避免上一集的 UA / Referer 留在会话里。
  Future<void> _applyMpvHeaderProps() async {
    await _mpvSet('user-agent', _mpvUserAgent);
    await _mpvSet('referrer', _mpvReferer);
  }

  final Player player;
  final VideoController controller;
  final void Function()? _onWin7SoftOnDirect;
  bool _softOnDirectRecoveryQueued = false;
  KotvMpvOpts _opts;
  bool _previewVideoOriginal = false;
  bool _previewAudioOriginal = false;
  final List<StreamSubscription> _subs = [];
  String _url = '';
  Map<String, String> _headers = const {};
  /// 本次 open 传入的 format（空 mime 失败时可锁 HLS 再开）。
  String? _openFormat;
  bool _formatRetried = false;
  bool _buffering = false;
  bool _repeatOne = false;
  /// 开播标定的直播会话（详情 live / 直播页）；点播勿被引擎 media-live 改写。
  bool _live;
  /// 引擎 `media-live`（只读守卫；不改缓冲、不挡 queueNext、不抑制片尾 completed）。
  bool _engineLive = false;
  /// 当前会话挂了 ClearKey（demuxer-lavf-o）；无缝排队不复用该会话。
  bool _drmSession = false;
  String? _clearKeyHex;
  int _speedBps = 0;
  late Future<void> _optsReady;
  /// 换源时本地尺寸清零；未 [_acceptSize] 前不采信 libmpv 残留宽高。
  int _w = 0;
  int _h = 0;
  bool _acceptSize = false;
  /// 无缝切入后 player.state.completed 可能仍为 true；用闸门对外报未完成，直到真正 EOF。
  bool? _completedGate;
  Map<String, String> _extraOpenProps = const {};
  /// mpv `duration/full`；无则回落 player.state.duration。
  Duration _durationFull = Duration.zero;
  bool _observedMpvProps = false;

  void setExtraOpenProps(Map<String, String> props) {
    _extraOpenProps = Map<String, String>.from(props);
  }

  void _clearVideoSize() {
    _acceptSize = false;
    _w = 0;
    _h = 0;
  }

  void _adoptPlayerSize() {
    _acceptSize = true;
    _w = player.state.width ?? 0;
    _h = player.state.height ?? 0;
  }

  /// 桌面起播：`open(play: false)` 让 media_kit 内部 `playlist-pos` 在暂停态做完，
  /// 再 [Player.play] 一次（`pause=no`）。不做轮询踢醒、不做二次兜底。
  ///
  /// **历史根因（Win7）：** media_kit `play()` 内部
  /// `_setPropertyFlag('pause', false)` 用 `calloc<Bool>(1)`（1 字节）承载
  /// `MPV_FORMAT_FLAG`，mpv 按 `int`（4 字节）读、`!!flag` 取值；高 3 字节是堆上
  /// 脏数据，Windows（CoTaskMemAlloc）常非零 → Dart 写 false，mpv 收到
  /// `Set property: pause=true`，于是「播放中、缓冲在涨、time-pos 不动，点一下暂停
  /// （cycle pause，无数据参数）才起播」。pub.dev 1.2.6 与上游 main 都未修，
  /// 由 `scripts/patch-media-kit.sh` 在 `flutter pub get` 后把 pub-cache 里的
  /// `calloc<Bool>(1)` 改为 `calloc<Int32>(1)`（主线 / Win7 线同版本同补丁，
  /// 打不上即中止打包）。应用层不再兜底。
  Future<void> _openThenUnpause(Media media) async {
    await player.open(media, play: false);
    await player.play();
  }

  /// 开播 lavf：已知 HLS 锁整表时间轴；否则按内容探测（含 ClearKey）。
  Future<void> _applyLavfForOpen({
    required String url,
    String? format,
    String? clearKey,
  }) async {
    await kotvApplyLavfForOpen(
      set: (k, v) async {
        await _mpvSet(k, v);
      },
      url: url,
      format: format,
      lavfO: kotvLavfOWithClearKey(clearKey),
    );
  }

  /// 空 format 且错误指向格式/加载失败时，锁 HLS mime 再开一次。
  Future<void> _maybeRetryHlsAfterError(String message) async {
    final url = _url;
    if (url.isEmpty) return;
    if (!kotvShouldRetryMpvHlsAfterError(
      url: url,
      format: _openFormat,
      alreadyRetried: _formatRetried,
      errorText: message,
    )) {
      return;
    }
    _formatRetried = true;
    _openFormat = 'application/x-mpegURL';
    final pos = position;
    try {
      await _applyLavfForOpen(url: url, format: _openFormat, clearKey: _clearKeyHex);
      final split = kotvSplitMpvHeaders(_headers);
      _mpvUserAgent = split.userAgent;
      _mpvReferer = split.referer;
      await _applyMpvHeaderProps();
      final media = Media(
        url,
        httpHeaders: split.fields.isEmpty ? null : split.fields,
        start: pos > Duration.zero ? pos : null,
      );
      await _openThenUnpause(media);
    } catch (_) {}
  }

  Future<void> _prepareOpts() async {
    try {
      final platform = player.platform;
      if (platform != null && platform.isVideoControllerAttached) {
        await platform.waitForVideoControllerInitializationIfAttached
            .timeout(const Duration(seconds: 8));
      } else {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final p2 = player.platform;
        if (p2 != null && p2.isVideoControllerAttached) {
          await p2.waitForVideoControllerInitializationIfAttached
              .timeout(const Duration(seconds: 8));
        }
      }
      await _opts.applyAfterAttach(player, live: _live);
      await _ensureMpvTimelineObservers();
    } catch (_) {}
  }

  /// 观测引擎时间轴：`duration/full`、`media-live`（时长只信引擎，不灌节目单）。
  Future<void> _ensureMpvTimelineObservers() async {
    if (_observedMpvProps) return;
    final platform = player.platform;
    if (platform == null) return;
    try {
      await (platform as dynamic).observeProperty('duration/full', (String raw) async {
        final sec = double.tryParse(raw.trim()) ?? 0;
        final next = sec > 0
            ? Duration(milliseconds: (sec * 1000).round())
            : Duration.zero;
        if (next == _durationFull) return;
        _durationFull = next;
        notifyListeners();
      });
      await (platform as dynamic).observeProperty('media-live', (String raw) async {
        if (!kotvAcceptEngineLive(
          already: _engineLive,
          reported: kotvParseMediaLiveFlag(raw),
        )) {
          return;
        }
        _engineLive = true;
        notifyListeners();
      });
      // Win7 直出落到软解：须换 D3D11 Player（见 [kotvWin7SoftOnDirectNeedsNewPlayer]）。
      if (kotvIsWindows7()) {
        await (platform as dynamic).observeProperty('hwdec-current', (String raw) async {
          final cur = raw.trim();
          if (!kotvWin7SoftOnDirectNeedsNewPlayer(direct: _opts.direct, hwdecCurrent: cur)) {
            return;
          }
          if (_softOnDirectRecoveryQueued) return;
          _softOnDirectRecoveryQueued = true;
          _onWin7SoftOnDirect?.call();
        });
      }
      _observedMpvProps = true;
    } catch (_) {}
  }

  Future<void> applyOpts(KotvMpvOpts opts) async {
    // Win7 建控制器时已按 hwdec 选定 ANGLE 后端，直出与否不能再改，改它要换 Player（见 [kotvMediaKitNeedsNewPlayer]）。
    _opts = kotvIsWindows7() ? opts.copyWith(direct: _opts.direct) : opts;
    // 缓冲只跟开播标定 _live；引擎 media-live 不改写属性。
    await _opts.applyAfterAttach(player, live: _live);
    notifyListeners();
  }

  @override
  String get engineLabel => '内置 MPV';

  @override
  bool get supportsStableVolume => true;

  @override
  bool get playing => player.state.playing;

  @override
  bool get completed => _completedGate ?? player.state.completed;

  @override
  bool get repeatOne => _repeatOne;

  @override
  Duration get position => player.state.position;

  @override
  Duration get duration {
    if (_durationFull > Duration.zero) return _durationFull;
    return player.state.duration;
  }

  @override
  Duration get buffered => player.state.buffer;

  @override
  bool get buffering => _buffering || player.state.buffering;

  @override
  int get networkSpeedBps => _speedBps;

  @override
  double get volume => player.state.volume;

  @override
  double get rate => player.state.rate;

  @override
  int get width => _w;

  @override
  int get height => _h;

  @override
  Stream<Duration> get positionStream => player.stream.position;

  @override
  Stream<Duration> get bufferedStream => player.stream.buffer;

  @override
  Stream<bool> get completedStream => _completedCtrl.stream;

  @override
  Stream<String> get queuedStartStream => _queuedStartCtrl.stream;

  /// media_kit 默认 `keep-open=yes`（见 [KotvPlayback.queueNext] 契约）。
  /// 有排队时主路径是 playlist 前进 → [_enterQueued]；此处拦截 completed 作竞态兜底。
  Future<void> _onPlayerCompleted(bool done) async {
    if (!done) {
      _completedGate = false;
      if (!_completedCtrl.isClosed) _completedCtrl.add(false);
      return;
    }
    // 仅图片轨、无音、无出画：keep-open 会 seek 到末帧并 completed，勿当正常片尾连播。
    // 起播守卫仍会因无尺寸抛 SilentVideo：点播可改开已下发透传 url，直播只走播放器 failover。
    if (_isUnplayableImageEof()) {
      _queued = null;
      await _setKeepOpen(true);
      _completedGate = false;
      if (!_completedCtrl.isClosed) _completedCtrl.add(false);
      notifyListeners();
      return;
    }
    final q = _queued;
    if (q != null && await _skipToQueued(q)) return;
    // 开播标定直播：时间轴/EOF 抖动勿当片尾硬切。引擎 media-live 不抑制 completed（点播仍可连播）。
    if (_live) return;
    // 无排队或切入失败：清掉排队态，交给详情硬切下一集。
    _queued = null;
    await _setKeepOpen(true);
    _completedGate = true;
    if (!_completedCtrl.isClosed) _completedCtrl.add(true);
  }

  /// PNG/MJPEG 等当「视频」却解不出尺寸、又无音轨：瞬时 EOF，不是播完。
  bool _isUnplayableImageEof() {
    if (width > 0 && height > 0) return false;
    if (_hasRealAudioTrack) return false;
    final videos = player.state.tracks.video
        .where((t) => !kotvIsPseudoMediaTrack('${t.id}'))
        .toList();
    if (videos.isEmpty) return false;
    return videos.every(
      (t) =>
          t.image == true ||
          t.albumart == true ||
          kotvIsImageMediaCodec(t.codec),
    );
  }

  /// 只排请求头和本集相同的：UA、Referer 是整个播放器共用的属性；
  /// 其余请求头按媒体写（加载该项时写 http-header-fields）。
  /// [startAt] 写入 Media.start，切入时由 libmpv 定位（片头），勿等 transition 后再 seek。
  /// 成功排队后 `keep-open=no`（见 [KotvPlayback.queueNext]）。
  @override
  Future<bool> queueNext({
    required String id,
    required String url,
    Map<String, String>? headers,
    String? format,
    List<Map<String, dynamic>> subs = const [],
    Duration startAt = Duration.zero,
  }) async {
    final h = kotvNormalizePlayHeaders(headers, url: url);
    // ClearKey 写在播放器全局 lavf；列表项无法带独立密钥。外挂字幕亦无 Media 字段可挂。
    if (_url.isEmpty || _live || _repeatOne || _drmSession || !mapEquals(h, _headers)) {
      return false;
    }
    await clearNext();
    final fields = kotvSplitMpvHeaders(h).fields;
    final mime = kotvPlayMime(url, format);
    final media = Media(
      url,
      httpHeaders: fields.isEmpty ? null : fields,
      start: startAt > Duration.zero ? startAt : null,
    );
    // media_kit Player.add 无法带 per-file 选项；HLS 先写会话 lavf，再 append，勿 playlist-remove
    // 打乱 media_kit 与 libmpv 列表（会破坏片尾 skip / 无缝换集）。
    try {
      if (kotvIsHls(url, mime)) {
        await _applyLavfForOpen(url: url, format: mime, clearKey: _clearKeyHex);
      }
      await player.add(media);
    } catch (_) {
      return false;
    }
    _queued = (id: id, url: url, media: media);
    await _setKeepOpen(false);
    return true;
  }

  /// 只留正在播的一项（也删掉无缝接上后留在前面的上一集）；恢复 `keep-open=yes`。
  @override
  Future<void> clearNext() async {
    final had = _queued != null;
    _queued = null;
    final current = player.state.playlist.index;
    for (var i = player.state.playlist.medias.length - 1; i >= 0; i--) {
      if (i == current) continue;
      try {
        await player.remove(i);
      } catch (_) {}
    }
    if (had) await _setKeepOpen(true);
  }

  @override
  Future<bool> skipToNext() async {
    final q = _queued;
    if (q == null) return false;
    return _skipToQueued(q);
  }

  /// 切入已 append 的下一集（手动下一集 / completed 竞态兜底）。
  ///
  /// 禁止 [Player.next] / [Player.jump] / [Player.play]：media_kit 在
  /// `completed==true` 时会先把 `playlist-pos` 置 0，等于重开本集。
  /// 统一经 [_mpvSet] 写 `playlist-pos` 与 `pause=no`。
  Future<bool> _skipToQueued(({String id, String url, Media media}) q) async {
    if (!identical(_queued, q) && _queued?.id != q.id) return false;
    final pl = player.state.playlist;
    if (_playlistUriAt(pl, pl.index) == q.media.uri) {
      _enterQueued(q);
      return true;
    }
    var nextIdx = _playlistIndexOfUri(pl, q.media.uri);
    if (nextIdx < 0) nextIdx = pl.index + 1;
    if (nextIdx < 0 || nextIdx >= pl.medias.length) return false;
    if (!await _mpvSet('playlist-pos', '$nextIdx')) return false;
    if (!await _mpvSet('pause', 'no')) return false;
    // playlist 观察回调可能稍后才到；若状态已切到目标则立刻记账。
    final after = player.state.playlist;
    if (_playlistUriAt(after, after.index) == q.media.uri) {
      _enterQueued(q);
    }
    return true;
  }

  String? _playlistUriAt(Playlist pl, int index) {
    if (index < 0 || index >= pl.medias.length) return null;
    return pl.medias[index].uri;
  }

  int _playlistIndexOfUri(Playlist pl, String uri) {
    for (var i = 0; i < pl.medias.length; i++) {
      if (pl.medias[i].uri == uri) return i;
    }
    return -1;
  }

  /// 有排队 → `keep-open=no`；否则 → `yes`（契约见 [KotvPlayback.queueNext]）。
  Future<void> _setKeepOpen(bool keep) async {
    await _mpvSet('keep-open', keep ? 'yes' : 'no');
  }

  void _enterQueued(({String id, String url, Media media}) q) {
    if (_queued == null || _queued!.id != q.id) return;
    _queued = null;
    unawaited(_setKeepOpen(true));
    _url = q.url;
    _engineLive = false;
    _openGen++;
    _openSerial++;
    // 无缝换集：勿清成 0x0。同分辨率时 width/height 流可能不重发，清掉会一直显示 0x0。
    _acceptSize = true;
    _adoptPlayerSize();
    _completedGate = false;
    if (!_completedCtrl.isClosed) _completedCtrl.add(false);
    if (!_queuedStartCtrl.isClosed) _queuedStartCtrl.add(q.id);
    notifyListeners();
  }

  /// media_kit 的 `Tracks` 永远带 `auto` / `no` 两个伪轨（未加载时也在），
  /// 所以不能用 `isNotEmpty` 判有无轨；只数真实轨。图片/封面轨不算实视频。
  bool get _hasRealVideoTrack => player.state.tracks.video.any(
        (t) => kotvIsRealVideoTrack(
          id: '${t.id}',
          codec: t.codec,
          image: t.image == true,
          albumart: t.albumart == true,
        ),
      );

  bool get _hasRealAudioTrack =>
      player.state.tracks.audio.any((t) => !kotvIsPseudoMediaTrack('${t.id}'));

  /// 文件已 loaded（对应原生 MPV 的 `_ready`）：track-list 已到、或已知时长、
  /// 或已出画/进度已走。之前没有这一层，守卫 open 当刻就把 media_kit
  /// 当成「已在播却黑屏」——立刻踢 play、起 8s 黑屏窗口，慢源加载 >16s 就被误切播放器。
  /// 图片轨也算 demux 已到（与「实视频」区分：后者才挡纯音频叠层）。
  bool get _loaded =>
      _hasRealVideoTrack ||
      _hasRealAudioTrack ||
      player.state.tracks.video.any((t) => !kotvIsPseudoMediaTrack('${t.id}')) ||
      player.state.duration > Duration.zero ||
      player.state.position > Duration.zero ||
      (width > 0 && height > 0);

  @override
  bool get hasVideoSourceHint {
    // 轨表未知时不判「无视频源」，交给黑屏窗口。
    if (!_hasRealVideoTrack && !_hasRealAudioTrack) return true;
    return _hasRealVideoTrack;
  }

  @override
  bool get isAudioOnlyContent => _hasRealAudioTrack && !_hasRealVideoTrack;

  @override
  List<KotvTrack> get audioTracks {
    return player.state.tracks.audio
        .where((t) => !kotvIsPseudoMediaTrack('${t.id}'))
        .map(_kotvTrackFromMediaKit)
        .toList();
  }

  @override
  List<KotvTrack> get videoTracks {
    return player.state.tracks.video
        .where((t) => !kotvIsPseudoMediaTrack('${t.id}'))
        .map(_kotvTrackFromMediaKit)
        .toList();
  }

  @override
  List<KotvTrack> get subtitleTracks {
    return player.state.tracks.subtitle
        .where((t) => !kotvIsPseudoMediaTrack('${t.id}'))
        .map(_kotvTrackFromMediaKit)
        .toList();
  }

  @override
  String? get currentAudioId {
    return player.state.track.audio.id;
  }

  @override
  String? get currentVideoId {
    return player.state.track.video.id;
  }

  @override
  String? get currentSubtitleId {
    return player.state.track.subtitle.id;
  }

  @override
  String? get currentSecondarySubtitleId => _currentSecondarySubtitleId;

  String? _currentSecondarySubtitleId;

  @override
  Future<void> open(
    String url, {
    Map<String, String>? headers,
    Map<String, dynamic>? drm,
    bool live = false,
    String? format,
    Duration startAt = Duration.zero,
    bool waitReady = true,
  }) async {
    _url = url;
    _live = live;
    _engineLive = false;
    _softOnDirectRecoveryQueued = false;
    _openFormat = format;
    _formatRetried = false;
    _headers = kotvNormalizePlayHeaders(headers, url: url);
    _durationFull = Duration.zero;
    // 换源清尺寸（与 Exo / 原生 MPV 一致）；避免 libmpv 残留宽高误判就绪。
    _clearVideoSize();
    _completedGate = null;
    notifyListeners();
    final clearKeyHex = kotvIsLocalClearKey(drm) ? kotvClearKeyHex(drm) : null;
    if (drm != null && drm.isNotEmpty && clearKeyHex == null) {
      throw StateError('MPV 不支持该 DRM，请用内置 ExoPlayer');
    }
    _drmSession = clearKeyHex != null;
    _clearKeyHex = clearKeyHex;
    await _optsReady;
    await _opts.applyAfterAttach(player, live: live);
    await _ensureMpvTimelineObservers();
    if (_extraOpenProps.isNotEmpty) {
      for (final e in _extraOpenProps.entries) {
        await _mpvSet(e.key, e.value);
      }
      _extraOpenProps = const {};
    }
    // start 经 Media 在 load 时定位（等同原生 loadfile start=），勿 open 后再 seek。
    // 302 由 libmpv 在这一次打开里跟。
    // UA / Referer 写独立属性；media_kit 只会把 httpHeaders 放进 http-header-fields。
    final split = kotvSplitMpvHeaders(_headers);
    _mpvUserAgent = split.userAgent;
    _mpvReferer = split.referer;
    final media = Media(
      url,
      httpHeaders: split.fields.isEmpty ? null : split.fields,
      start: startAt > Duration.zero ? startAt : null,
    );
    _queued = null;
    _openGen++;
    final gen = _openGen;
    final job = () async {
      await _applyLavfForOpen(url: url, format: format, clearKey: clearKeyHex);
      if (gen != _openGen || _url.isEmpty) return;
      await _applyMpvHeaderProps();
      if (gen != _openGen || _url.isEmpty) return;
      await _openThenUnpause(media);
    }();
    await job;
    // 新媒开始加载后再允许采信尺寸（避免上一集残留宽高）。
    _acceptSize = true;
    _adoptPlayerSize();
    notifyListeners();
    // 与原生 MPV / Exo 一致：未 loaded 视作「未在播的缓冲」只等；loaded 后才进黑屏判定。
    // stop()/换集会重置 media_kit 状态（_loaded 回 false），必须用会话号让旧守卫
    // 看到「不缓冲且已死」而退出，否则 open() 永远不返回。
    _openSerial++;
    if (waitReady) {
      await awaitReadyAfterOpen();
    }
  }


  @override
  Future<void> awaitReadyAfterOpen() async {
    final session = _openSerial;
    bool sameSession() => _openSerial == session && _url.isNotEmpty;
    await kotvGuardSilentVideo(
      hasVideoSize: () => width > 0 && height > 0,
      isBuffering: () => sameSession() && (!_loaded || buffering),
      sessionAlive: () => sameSession() && !completed && _loaded,
      isPlaying: () => playing,
      position: () => position,
      duration: () => duration,
      isLiveContent: () =>
          kotvIsLiveForGuard(markedLive: _live, engineLive: _engineLive),
      onFixVideoSource: tryFixVideoSource,
      isAudioOnly: () => isAudioOnlyContent,
      hasVideoSource: () => hasVideoSourceHint,
    );
  }

  @override
  Future<void> stop() => _stopUnload(reason: 'stop');

  /// 换集/换台：只卸文件。Player 留到离页或换引擎再 dispose。
  @override
  Future<void> stopForEpisodeSwitch() => _stopUnload(reason: 'stopForEpisodeSwitch');

  Future<void> _stopUnload({required String reason}) async {
    _url = '';
    _queued = null;
    _drmSession = false;
    _clearKeyHex = null;
    _openFormat = null;
    _formatRetried = false;
    _engineLive = false;
    _durationFull = Duration.zero;
    _completedGate = null;
    _clearVideoSize();
    _speedBps = 0;
    try {
      await player.stop();
    } catch (_) {}
    notifyListeners();
  }

  @override
  Future<void> release() async {
    // 离开页：先 pause 停声，再 stop；真正 dispose 由页面 kotvDisposeMpvPlayer 完成。
    try {
      await player.pause();
    } catch (_) {}
    await stop();
  }

  @override
  Future<void> playOrPause() => player.playOrPause();

  @override
  Future<void> play() async {
    await kotvPlayRestartingFromEndIfNeeded(
      completed: completed,
      position: position,
      duration: duration,
      seekZero: () async {
        await player.seek(Duration.zero);
        _completedGate = false;
      },
      play: () => player.play(),
    );
  }

  @override
  Future<void> pause() => player.pause();

  @override
  Future<void> seek(Duration d) => player.seek(d);

  @override
  Future<void> setVolume(double v) => player.setVolume(v.clamp(0, 100));

  @override
  Future<void> setRate(double r) => player.setRate(kotvClampPlayRate(r));

  @override
  Future<void> setRepeatOne(bool on) async {
    _repeatOne = on;
    if (on) await clearNext();
    await player.setPlaylistMode(on ? PlaylistMode.single : PlaylistMode.none);
  }

  @override
  Future<void> setDecodeMode(String mode) async {
    _opts = _opts.copyWith(decodeMode: mode);
    await applyOpts(_opts);
  }

  @override
  bool get supportsDirectOutput => kotvIsWindows7();

  @override
  bool get directOutput => _opts.direct;

  @override
  Future<void> setFxPreview({bool? videoOriginal, bool? audioOriginal}) async {
    var changed = false;
    if (videoOriginal != null && videoOriginal != _previewVideoOriginal) {
      _previewVideoOriginal = videoOriginal;
      changed = true;
    }
    if (audioOriginal != null && audioOriginal != _previewAudioOriginal) {
      _previewAudioOriginal = audioOriginal;
      changed = true;
    }
    if (!changed) return;
    final props = _opts.fxPreviewProperties(
      videoOriginal: _previewVideoOriginal,
      audioOriginal: _previewAudioOriginal,
    );
    for (final e in props.entries) {
      await _mpvSet(e.key, e.value);
    }
  }

  @override
  Future<void> setStableVolume(bool on) async {
    _opts = _opts.copyWith(stableVolume: on);
    // 和其它音效合成同一条 af，后续 applyOpts 也不会把它冲掉。
    await _mpvSet('af', '${_opts.equalizerChannelArgs()['audioAf']}');
  }

  /// 桌面 libmpv：Texture 常与视口同尺寸，Flutter BoxFit 无效；须写 keepaspect/panscan/video-aspect-override。
  @override
  Future<void> setVideoScale(String mode) async {
    final m = mode.trim().isEmpty ? 'default' : mode.trim();
    switch (m.toLowerCase()) {
      case 'fill':
        await _mpvSet('keepaspect', 'no');
        await _mpvSet('panscan', '0');
        await _mpvSet('video-aspect-override', 'no');
      case 'zoom':
        await _mpvSet('keepaspect', 'yes');
        await _mpvSet('panscan', '1');
        await _mpvSet('video-aspect-override', 'no');
      case '16:9':
        await _mpvSet('keepaspect', 'yes');
        await _mpvSet('panscan', '0');
        await _mpvSet('video-aspect-override', '16:9');
      case '4:3':
        await _mpvSet('keepaspect', 'yes');
        await _mpvSet('panscan', '0');
        await _mpvSet('video-aspect-override', '4:3');
      default:
        await _mpvSet('keepaspect', 'yes');
        await _mpvSet('panscan', '0');
        await _mpvSet('video-aspect-override', 'no');
    }
  }

  @override
  Future<void> tryFixVideoSource() async {
    // open 已 prepare+play；这里只再确保 unpause，勿 seek(0)。
    try {
      await player.play();
    } catch (_) {}
  }

  @override
  Future<void> setAudioTrack(String id) async {
    if (kotvAudioIsAuto(id)) {
      await player.setAudioTrack(AudioTrack.auto());
      return;
    }
    for (final t in player.state.tracks.audio) {
      if ('${t.id}' == id) {
        await player.setAudioTrack(t);
        return;
      }
    }
  }

  @override
  Future<void> setVideoTrack(String id) async {
    if (kotvAudioIsAuto(id) || id.isEmpty) {
      await player.setVideoTrack(VideoTrack.auto());
      return;
    }
    for (final t in player.state.tracks.video) {
      if ('${t.id}' == id) {
        await player.setVideoTrack(t);
        return;
      }
    }
  }

  @override
  Future<void> setSubtitleTrack(String id) async {
    if (id.isEmpty || kotvSubtitleIsOff(id)) {
      await player.setSubtitleTrack(SubtitleTrack.no());
      return;
    }
    if (kotvSubtitleIsAuto(id)) {
      await player.setSubtitleTrack(SubtitleTrack.auto());
      return;
    }
    for (final t in player.state.tracks.subtitle) {
      if ('${t.id}' == id) {
        await player.setSubtitleTrack(t);
        return;
      }
    }
  }

  @override
  bool get supportsDiscNav => true;

  @override
  Future<String?> activeDecoderLabel() async {
    final cur = '${await _mpvProp('hwdec-current') ?? ''}';
    return kotvMpvHwdecLabel(cur);
  }

  Future<dynamic> _mpvProp(String name) async {
    try {
      final platform = player.platform;
      if (platform == null) return null;
      return await (platform as dynamic).getProperty(name);
    } catch (_) {
      return null;
    }
  }

  Future<bool> _mpvSet(String name, String value) async {
    try {
      final platform = player.platform;
      if (platform == null) return false;
      await (platform as dynamic).setProperty(name, value);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _mpvCmd(List<String> args) async {
    try {
      final platform = player.platform;
      if (platform == null) return;
      await (platform as dynamic).command(args);
    } catch (_) {}
  }

  @override
  Future<List<KotvTrack>> discTitles() async {
    final raw = await _mpvProp('disc-titles');
    final n = int.tryParse('$raw') ?? 0;
    if (n <= 0) return const [];
    return [
      for (var i = 1; i <= n; i++) KotvTrack(id: '$i', label: '标题 $i'),
    ];
  }

  @override
  Future<List<KotvTrack>> discChapters() async {
    final raw = await _mpvProp('chapters');
    final n = int.tryParse('$raw') ?? 0;
    if (n <= 0) return const [];
    return [
      for (var i = 0; i < n; i++) KotvTrack(id: '$i', label: '章节 ${i + 1}'),
    ];
  }

  @override
  Future<void> setDiscTitle(int index) async {
    if (index < 1) return;
    await _mpvSet('disc-title', '$index');
  }

  @override
  Future<void> setDiscChapter(int index) async {
    if (index < 0) return;
    await _mpvSet('chapter', '$index');
  }

  @override
  Future<void> openDiscMenu() async {
    await _mpvCmd(const ['discnav', 'menu']);
  }

  @override
  Future<void> addSubtitleFile(String path, {String? title}) async {
    final p = path.trim();
    if (p.isEmpty) return;
    try {
      var uri = p;
      if (!p.contains('://')) {
        uri = Uri.file(p).toString();
      }
      await player.setSubtitleTrack(
        SubtitleTrack.uri(uri, title: (title ?? '').trim().isEmpty ? null : title),
      );
    } catch (_) {}
  }

  @override
  Future<void> setSecondarySubtitleTrack(String id) async {
    final key = id.trim().toLowerCase();
    if (key.isEmpty || key == 'no' || key == 'off' || key == 'none') {
      await _mpvSet('secondary-sid', 'no');
      _currentSecondarySubtitleId = null;
    } else if (key == 'auto') {
      // 自动：选主轨以外的第一条字幕。
      final subs = subtitleTracks;
      final primary = currentSubtitleId;
      final alt = subs.where((t) => t.id != primary).toList();
      if (alt.isEmpty) {
        await _mpvSet('secondary-sid', 'no');
        _currentSecondarySubtitleId = null;
      } else {
        await _mpvSet('secondary-sid', alt.first.id);
        _currentSecondarySubtitleId = alt.first.id;
      }
    } else {
      await _mpvSet('secondary-sid', id.trim());
      _currentSecondarySubtitleId = id.trim();
    }
    notifyListeners();
  }

  @override
  Future<void> setSubtitleStyle({
    double? scale,
    double? pos,
    double? secondaryPos,
    bool forceStyle = false,
    String? color,
    String? borderColor,
    double? borderSize,
    String? bgColor,
    String? edgeType,
    bool useSystemStyle = false,
    double? textOpacity,
    double? bgOpacity,
    double? edgeOpacity,
    double? shadowStrength,
    String? font,
    String? fontPath,
  }) async {
    if (scale != null) {
      await _mpvSet('sub-scale', scale.clamp(0.5, 2.0).toStringAsFixed(2));
    }
    if (pos != null) {
      await _mpvSet('sub-pos', kotvSubtitlePosToMpv(pos).toStringAsFixed(1));
    }
    if (secondaryPos != null) {
      await _mpvSet('secondary-sub-pos', secondaryPos.toStringAsFixed(1));
    }
    final applyLooks = forceStyle || useSystemStyle;
    if (applyLooks && color != null && color.trim().isNotEmpty) {
      await _mpvSet('sub-color', color.trim());
    }
    if (applyLooks && borderColor != null && borderColor.trim().isNotEmpty) {
      await _mpvSet('sub-border-color', borderColor.trim());
    }
    if (applyLooks && borderSize != null) {
      await _mpvSet('sub-border-size', borderSize.clamp(0.0, 8.0).toStringAsFixed(1));
    }
    if (applyLooks && bgColor != null && bgColor.trim().isNotEmpty) {
      await _mpvSet('sub-back-color', bgColor.trim());
    }
    final edge = (edgeType ?? '').trim().toLowerCase();
    final strength = ((shadowStrength ?? 50).clamp(0, 100) / 50.0).clamp(0.0, 2.5);
    if (applyLooks && edge == 'none') {
      await _mpvSet('sub-border-size', '0');
      await _mpvSet('sub-shadow-offset', '0');
    } else if (applyLooks && edge == 'shadow') {
      await _mpvSet('sub-shadow-offset', (2.0 * strength).toStringAsFixed(2));
    } else if (applyLooks && (edge == 'raised' || edge == 'depressed')) {
      await _mpvSet('sub-shadow-offset', (1.5 * strength).toStringAsFixed(2));
    }
    if (applyLooks && font != null && font.trim().isNotEmpty && font.trim().toLowerCase() != 'default') {
      final f = font.trim().toLowerCase();
      final mpvFont = switch (f) {
        'sans' || 'sans-serif' => 'sans-serif',
        'serif' => 'serif',
        'mono' || 'monospace' => 'monospace',
        _ => font.trim(),
      };
      await _mpvSet('sub-font', mpvFont);
    }
    await _mpvSet('sub-ass-override', forceStyle ? 'force' : 'scale');
  }

  @override
  Future<void> setSubtitleOffsetMs(int offsetMs) async {
    final sec = (offsetMs.clamp(-300000, 300000) / 1000.0);
    await _mpvSet('sub-delay', sec.toStringAsFixed(3));
  }

  @override
  Future<void> setAudioOffsetMs(int offsetMs) async {
    final ms = offsetMs.clamp(-10000, 10000);
    _opts = _opts.copyWith(audioOffsetMs: ms);
    await _mpvSet('audio-delay', (ms / 1000.0).toStringAsFixed(3));
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    unawaited(_queuedStartCtrl.close());
    unawaited(_completedCtrl.close());
    super.dispose();
  }
}
