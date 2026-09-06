import 'dart:async';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'buffer_budget.dart';
import 'kotv_playback.dart';
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
Player kotvCreateMpvPlayer({bool live = false}) {
  if (live) {
    return Player(
      configuration: const PlayerConfiguration(
        logLevel: MPVLogLevel.error,
      ),
    );
  }
  final budget = KotvBufferBudget.bytes();
  return Player(
    configuration: PlayerConfiguration(
      bufferSize: budget,
      logLevel: MPVLogLevel.error,
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
    // 网速浮层走 KotvTraffic；勿轮询 demuxer-cache-state（换集/换台重建 demuxer 时易卡音）。
    _optsReady = _prepareOpts();
  }

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
  /// open 后短时忽略 pause / 误触 playOrPause（Windows 上 playlist-pos 后易回 pause）。
  DateTime? _forcePlayUntil;

  void _armForcePlay([Duration d = const Duration(milliseconds: 1600)]) {
    _forcePlayUntil = DateTime.now().add(d);
  }

  bool get _inForcePlayWindow {
    final u = _forcePlayUntil;
    return u != null && DateTime.now().isBefore(u);
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

  @override
  bool get hasVideoSourceHint {
    final tracks = player.state.tracks;
    return tracks.video.isNotEmpty;
  }

  @override
  bool get isAudioOnlyContent {
    final tracks = player.state.tracks;
    return tracks.video.isEmpty && tracks.audio.isNotEmpty;
  }

  @override
  List<KotvTrack> get audioTracks {
    return player.state.tracks.audio
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
    // 对齐 TV MpvPlayerEngine.prepareAndPlay：setMediaItem 后立刻 prepare+play，
    // 不等 Flutter 层缓冲门槛（play:false→等尺寸易卡音/偶发不起播）。
    await player.open(media, play: true);
    // media_kit open 内部顺序是 pause→loadlist→unpause→playlist-pos；
    // 桌面（尤其 Windows）设 playlist-pos 后常又回到 pause，必须再强制 play。
    try {
      await player.play();
    } catch (_) {}
    _armForcePlay();
    // 新媒开始加载后再允许采信尺寸（避免上一集残留宽高）。
    _acceptSize = true;
    _adoptPlayerSize();
    notifyListeners();
    await kotvGuardSilentVideo(
      hasVideoSize: () => width > 0 && height > 0,
      isBuffering: () => buffering,
      sessionAlive: () => !completed && (_url.isNotEmpty),
      isPlaying: () => playing,
      position: () => position,
      duration: () => duration,
      isLiveContent: () => live || (duration <= Duration.zero && playing),
      onFixVideoSource: tryFixVideoSource,
      isAudioOnly: () => isAudioOnlyContent,
      hasVideoSource: () => hasVideoSourceHint,
    );
    // 守卫等待期间 Texture 附着/布局抖动可能把 mpv 又 pause；起播结束再确保一次。
    if (!player.state.playing) {
      try {
        await player.play();
      } catch (_) {}
    }
    _armForcePlay();
  }

  @override
  Future<void> stop() async {
    // 对齐 TV：换集只停播，不 dispose Player（离开页走 kotvDisposeMpvPlayer）。
    _forcePlayUntil = null;
    _url = '';
    _clearVideoSize();
    _speedBps = 0;
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

  @override
  Future<void> playOrPause() async {
    if (_inForcePlayWindow) {
      if (player.state.playing) return;
      await player.play();
      return;
    }
    await player.playOrPause();
  }

  @override
  Future<void> play() => player.play();

  @override
  Future<void> pause() async {
    // 起播保护窗内忽略 pause，避免误触/竞态把刚起播掐掉。
    if (_inForcePlayWindow) return;
    await player.pause();
  }

  @override
  Future<void> seek(Duration d) => player.seek(d);

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
