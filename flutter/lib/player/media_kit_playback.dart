import 'dart:async';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'buffer_budget.dart';
import 'kotv_playback.dart';
import 'mpv_opts.dart';
import 'play_headers.dart';
import 'silent_video_guard.dart';

/// 安全释放 libmpv [Player]：先停播、给事件线程留出排空时间，再 dispose。
Future<void> kotvDisposeMpvPlayer(Player? player) async {
  if (player == null) return;
  try {
    await player.pause();
  } catch (_) {}
  try {
    await player.stop();
  } catch (_) {}
  await Future<void>.delayed(const Duration(milliseconds: 400));
  try {
    await player.dispose();
  } catch (_) {}
}

/// 按缓冲预算创建 [Player]，避免 media_kit 默认 32MiB 再被事后猛改造成起播抖动。
Player kotvCreateMpvPlayer() {
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
  MediaKitPlayback(this.player, {VideoController? controller, KotvMpvOpts? opts})
      : _opts = opts ?? const KotvMpvOpts(),
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
      final wasBuffering = _buffering;
      _buffering = v;
      if (v) {
        unawaited(_pollCacheSpeed());
      } else {
        _speedBps = 0;
        if (wasBuffering && _url.isNotEmpty && !player.state.completed) {
          unawaited(_kickAfterBufferReady());
        }
      }
      notifyListeners();
    }));
    _subs.add(player.stream.width.listen((_) => notifyListeners()));
    _subs.add(player.stream.height.listen((_) => notifyListeners()));
    _subs.add(player.stream.volume.listen((_) => notifyListeners()));
    _subs.add(player.stream.rate.listen((_) => notifyListeners()));
    _subs.add(player.stream.completed.listen((_) => notifyListeners()));
    _speedTimer = Timer.periodic(const Duration(milliseconds: 400), (_) {
      if (_buffering || player.state.buffering || player.state.playing) {
        unawaited(_pollCacheSpeed());
      }
    });
    _optsReady = _prepareOpts();
  }

  final Player player;
  final VideoController controller;
  KotvMpvOpts _opts;
  final List<StreamSubscription> _subs = [];
  String _url = '';
  Map<String, String> _headers = const {};
  bool _buffering = false;
  bool _live = false;
  int _speedBps = 0;
  Timer? _speedTimer;
  bool _speedBusy = false;
  int _lastCacheBytes = -1;
  DateTime? _lastCacheAt;
  int _resumeKickGen = 0;
  late Future<void> _optsReady;

  /// mpv `paused-for-cache` 结束时常出现：缓冲条已满、浮层消失，但 time-pos 仍不走，
  /// 须用户点播停或 seek 才动。缓冲结束且前方已有数据时补一次 play/seek。
  Future<void> _kickAfterBufferReady() async {
    if (_live || _url.isEmpty) return;
    final gen = _resumeKickGen;
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (gen != _resumeKickGen || _url.isEmpty) return;

    final pos = position;
    final buf = buffered;
    if (buf <= pos + const Duration(milliseconds: 500)) return;

    if (!playing) {
      try {
        await player.play();
      } catch (_) {}
      return;
    }

    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (gen != _resumeKickGen || _url.isEmpty || !playing) return;
    if (position <= pos + const Duration(milliseconds: 250)) {
      try {
        await player.seek(pos);
        await player.play();
      } catch (_) {}
    }
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

  Future<void> _pollCacheSpeed() async {
    if (_speedBusy) return;
    _speedBusy = true;
    try {
      final platform = player.platform;
      if (platform == null) return;
      final cache = await (platform as dynamic).getProperty('demuxer-cache-state');
      if (cache is! Map) return;
      final fwd = cache['forward-bytes'];
      if (fwd is! num) return;
      final bytes = fwd.toInt();
      final now = DateTime.now();
      if (_lastCacheBytes >= 0 && _lastCacheAt != null) {
        final dt = now.difference(_lastCacheAt!).inMilliseconds;
        if (dt > 200) {
          final delta = bytes - _lastCacheBytes;
          if (delta > 0) _speedBps = (delta * 1000 / dt).round();
        }
      }
      _lastCacheBytes = bytes;
      _lastCacheAt = now;
      notifyListeners();
    } catch (_) {
    } finally {
      _speedBusy = false;
    }
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
  int get width => player.state.width ?? 0;

  @override
  int get height => player.state.height ?? 0;

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
    _resumeKickGen++;
    _headers = kotvNormalizePlayHeaders(headers, url: url);
    if (drm != null && drm.isNotEmpty) {
      throw StateError('MPV 不支持 DRM，请用内置 ExoPlayer');
    }
    await _optsReady;
    if (live) {
      await _opts.applyAfterAttach(player, live: true);
    }
    final media = Media(url, httpHeaders: _headers.isEmpty ? null : _headers);
    await player.open(media);
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
  }

  @override
  Future<void> stop() async {
    _resumeKickGen++;
    _url = '';
    return player.stop();
  }

  @override
  Future<void> playOrPause() => player.playOrPause();

  @override
  Future<void> play() => player.play();

  @override
  Future<void> pause() => player.pause();

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
    try {
      await player.seek(Duration.zero);
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
    _speedTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }
}
