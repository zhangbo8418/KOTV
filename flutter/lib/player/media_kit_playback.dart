import 'dart:async';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'buffer_budget.dart';
import 'kotv_playback.dart';
import 'mpv_diag.dart';
import 'mpv_opts.dart';
import 'play_headers.dart';
import 'silent_video_guard.dart';

/// 安全释放 libmpv [Player]：先停播、给事件线程留出排空时间，再 dispose。
/// 各桌面平台（Win / macOS / Linux）共用 [kotvTeardownPlayback]。
Future<void> kotvDisposeMpvPlayer(Player? player) async {
  if (player == null) return;
  await kotvTeardownPlayback(
    stop: () => player.stop(),
    dispose: () => player.dispose(),
  );
}

/// 按缓冲预算创建 [Player]。
///
/// [live]=true：对齐 TV，不套点播 KotvBufferBudget；media_kit 仅用库默认 bufferSize
///（其内部会写 demuxer-max-bytes，应用层不再二次改写）。
///
/// [conf]：用户「MPV 配置」文本，仅用于取 `kotv-log=` 决定 libmpv 日志级别
///（默认 info，落盘到 [KotvMpvDiag.fileName]）。
Player kotvCreateMpvPlayer({bool live = false, String conf = ''}) {
  final logLevel = KotvMpvDiag.logLevelFromConf(conf);
  if (live) {
    return Player(
      configuration: PlayerConfiguration(
        logLevel: logLevel,
      ),
    );
  }
  final budget = KotvBufferBudget.bytes();
  return Player(
    configuration: PlayerConfiguration(
      bufferSize: budget,
      logLevel: logLevel,
    ),
  );
}

String _trackLabel(dynamic t) {
  if (t.title?.isNotEmpty == true) return t.title! as String;
  if (t.language?.isNotEmpty == true) return t.language! as String;
  return t.id as String;
}

/// media_kit / libmpv（桌面 / iOS 等非 Android 原生插件路径）。
class MediaKitPlayback extends KotvPlayback {
  /// [live]=true：构造期 [_prepareOpts] 就跳过点播 demuxer（直播页必须传，避免先写入点播预算）。
  MediaKitPlayback(
    this.player, {
    VideoController? controller,
    KotvMpvOpts? opts,
    bool live = false,
  })  : _opts = opts ?? const KotvMpvOpts(),
        _live = live,
        controller = controller ??
            VideoController(
              player,
              configuration: (opts ?? const KotvMpvOpts()).videoControllerConfiguration(),
            ) {
    _subs.add(player.stream.playing.listen((_) => notifyListeners()));
    _subs.add(player.stream.position.listen((_) => notifyListeners()));
    _subs.add(player.stream.duration.listen((_) => notifyListeners()));
    _subs.add(player.stream.buffer.listen((_) => notifyListeners()));
    _subs.add(player.stream.buffering.listen((v) {
      _buffering = v;
      if (!v) _speedBps = 0;
      notifyListeners();
    }));
    _subs.add(player.stream.width.listen((w) {
      if (!_acceptSize) return;
      _w = w ?? 0;
      notifyListeners();
    }));
    _subs.add(player.stream.height.listen((h) {
      if (!_acceptSize) return;
      _h = h ?? 0;
      notifyListeners();
    }));
    _subs.add(player.stream.volume.listen((_) => notifyListeners()));
    _subs.add(player.stream.rate.listen((_) => notifyListeners()));
    _subs.add(player.stream.completed.listen((_) => notifyListeners()));
    // libmpv 日志落盘（AO/VO 初始化、pause 写入等），定位桌面起播停滞。
    _diag = KotvMpvDiag.enabledFromConf(_opts.conf);
    if (_diag) {
      _subs.add(KotvMpvDiag.attach(player, tag: live ? 'live' : 'vod'));
    }
    // 网速浮层走 KotvTraffic；勿轮询 demuxer-cache-state（换集/换台重建 demuxer 时易卡音）。
    _optsReady = _prepareOpts();
  }

  bool _diag = false;
  int _openSerial = 0;

  final Player player;
  final VideoController controller;
  KotvMpvOpts _opts;
  final List<StreamSubscription> _subs = [];
  String _url = '';
  Map<String, String> _headers = const {};
  bool _buffering = false;
  bool _live;
  int _speedBps = 0;
  late Future<void> _optsReady;
  /// 对齐 Exo/原生 MPV：换源时本地尺寸清零；未 [_acceptSize] 前不采信 libmpv 残留宽高。
  int _w = 0;
  int _h = 0;
  bool _acceptSize = false;

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
  /// **历史根因（Win7 kotv-mpv.log 实锤）：** media_kit `play()` 内部
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
    } catch (_) {}
  }

  Future<void> applyOpts(KotvMpvOpts opts) async {
    _opts = opts;
    await _opts.applyAfterAttach(player, live: _live);
    notifyListeners();
  }

  @override
  String get engineLabel => '内置 MPV';

  @override
  bool get playing => player.state.playing;

  @override
  bool get completed => player.state.completed;

  @override
  Duration get position => player.state.position;

  @override
  Duration get duration => player.state.duration;

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
  Stream<bool> get completedStream => player.stream.completed;

  /// media_kit 的 `Tracks` 永远带 `auto` / `no` 两个伪轨（未加载时也在），
  /// 所以不能用 `isNotEmpty` 判有无轨；只数真实轨。
  bool get _hasRealVideoTrack =>
      player.state.tracks.video.any((t) => !kotvIsPseudoMediaTrack('${t.id}'));

  bool get _hasRealAudioTrack =>
      player.state.tracks.audio.any((t) => !kotvIsPseudoMediaTrack('${t.id}'));

  /// 文件已 loaded（对齐原生 MPV 的 `_ready`）：track-list 已到、或已知时长、
  /// 或已出画/进度已走。之前没有这一层，守卫 open 当刻就把 media_kit
  /// 当成「已在播却黑屏」——立刻踢 play、起 8s 黑屏窗口，慢源加载 >16s 就被误切播放器。
  bool get _loaded =>
      _hasRealVideoTrack ||
      _hasRealAudioTrack ||
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
        .map((t) => KotvTrack(id: '${t.id}', label: _trackLabel(t)))
        .toList();
  }

  @override
  List<KotvTrack> get videoTracks {
    return player.state.tracks.video
        .where((t) => !kotvIsPseudoMediaTrack('${t.id}'))
        .map((t) => KotvTrack(id: '${t.id}', label: _trackLabel(t)))
        .toList();
  }

  @override
  List<KotvTrack> get subtitleTracks {
    return player.state.tracks.subtitle
        .where((t) => !kotvIsPseudoMediaTrack('${t.id}'))
        .map((t) => KotvTrack(id: '${t.id}', label: _trackLabel(t)))
        .toList();
  }

  @override
  String? get currentAudioId {
    final t = player.state.track.audio;
    if (t == null) return 'auto';
    return '${t.id}';
  }

  @override
  String? get currentVideoId {
    final t = player.state.track.video;
    if (t == null) return 'auto';
    return '${t.id}';
  }

  @override
  String? get currentSubtitleId {
    final t = player.state.track.subtitle;
    if (t == null) return 'no';
    return '${t.id}';
  }

  @override
  Future<void> open(
    String url, {
    Map<String, String>? headers,
    Map<String, dynamic>? drm,
    bool live = false,
  }) async {
    _url = url;
    _live = live;
    _headers = kotvNormalizePlayHeaders(headers, url: url);
    // 换源清尺寸（对齐 Exo / 原生 MPV）；避免 libmpv 残留宽高误判就绪。
    _clearVideoSize();
    notifyListeners();
    if (drm != null && drm.isNotEmpty) {
      throw StateError('MPV 不支持 DRM，请用内置 ExoPlayer');
    }
    await _optsReady;
    // 直播：对齐 TV，不写 demuxer-max-bytes/cache-secs；点播才写入 KotvBufferBudget。
    await _opts.applyAfterAttach(player, live: live);
    final media = Media(url, httpHeaders: _headers.isEmpty ? null : _headers);
    if (_diag) {
      KotvMpvDiag.note('open live=$live hwdec=${_opts.hwdecValue()} '
          'gpu-api=${_opts.gpuApi} ${KotvMpvDiag.hostOf(url)}');
    }
    await _openThenUnpause(media);
    if (_diag) {
      KotvMpvDiag.note('open done (play sent) dart.playing=${player.state.playing}');
      KotvMpvDiag.scheduleOpenSnapshots(player);
    }
    // 新媒开始加载后再允许采信尺寸（避免上一集残留宽高）。
    _acceptSize = true;
    _adoptPlayerSize();
    notifyListeners();
    // 对齐原生 MPV / Exo：未 loaded 视作「未在播的缓冲」只等；loaded 后才进黑屏判定。
    // stop()/换集会重置 media_kit 状态（_loaded 回 false），必须用会话号让旧守卫
    // 看到「不缓冲且已死」而退出，否则 open() 永远不返回。
    final session = ++_openSerial;
    bool sameSession() => _openSerial == session && _url.isNotEmpty;
    await kotvGuardSilentVideo(
      hasVideoSize: () => width > 0 && height > 0,
      isBuffering: () => sameSession() && (!_loaded || buffering),
      sessionAlive: () => sameSession() && !completed && _loaded,
      isPlaying: () => playing,
      position: () => position,
      duration: () => duration,
      isLiveContent: () => live || (duration <= Duration.zero && playing),
      onFixVideoSource: tryFixVideoSource,
      isAudioOnly: () => isAudioOnlyContent,
      hasVideoSource: () => hasVideoSourceHint,
    );
  }

  @override
  Future<void> stop() async {
    // 对齐 TV：换集只停播，不 dispose Player（离开页走 kotvDisposeMpvPlayer）。
    _url = '';
    _clearVideoSize();
    _speedBps = 0;
    if (_diag) KotvMpvDiag.note('stop');
    try {
      await player.stop();
    } catch (_) {}
    notifyListeners();
  }

  @override
  Future<void> release() async {
    // Player 由页面 kotvDisposeMpvPlayer 释放（对齐 TV engine.release）。
    await stop();
  }

  /// 用户操作前后各拍一次快照：正是「点暂停/拖进度条才起播」的关键瞬间。
  Future<void> _traced(String what, Future<void> Function() action) async {
    if (!_diag) return action();
    KotvMpvDiag.note('$what dart.playing=${player.state.playing} pos=${player.state.position}');
    await KotvMpvDiag.snapshot(player, reason: 'before-$what');
    await action();
    Timer(const Duration(milliseconds: 1500), () {
      unawaited(KotvMpvDiag.snapshot(player, reason: 'after-$what+1.5s'));
    });
  }

  @override
  Future<void> playOrPause() => _traced('playOrPause', player.playOrPause);

  @override
  Future<void> play() => _traced('play', player.play);

  @override
  Future<void> pause() => _traced('pause', player.pause);

  @override
  Future<void> seek(Duration d) => _traced('seek(${d.inMilliseconds}ms)', () => player.seek(d));

  @override
  Future<void> setVolume(double v) => player.setVolume(v.clamp(0, 100));

  @override
  Future<void> setRate(double r) => player.setRate(r);

  @override
  Future<void> setRepeatOne(bool on) async {
    await player.setPlaylistMode(on ? PlaylistMode.single : PlaylistMode.none);
  }

  @override
  Future<void> setDecodeMode(String mode) async {
    _opts = _opts.copyWith(decodeMode: mode);
    await applyOpts(_opts);
  }

  @override
  Future<void> setStableVolume(bool on) async {
    try {
      await (player.platform as dynamic).setProperty('af', on ? 'loudnorm' : '');
    } catch (_) {
      try {
        await (player.platform as dynamic).setProperty('af', on ? 'dynaudnorm' : '');
      } catch (_) {}
    }
  }

  @override
  Future<void> tryFixVideoSource() async {
    // 对齐 TV：open 已 prepare+play；这里只再确保 unpause，勿 seek(0)。
    if (_diag) KotvMpvDiag.note('tryFixVideoSource (silent-video guard) -> play');
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
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }
}
