import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fvp/mdk.dart';

import 'buffer_budget.dart';
import 'fvp_decoders.dart';
import 'fvp_register.dart';
import 'kotv_playback.dart';
import 'play_headers.dart';
import 'silent_video_guard.dart';

/// 页内 FVP（libmdk）：会话级复用同一 [Player]（对齐 TV MPV/Exo 换集不重建）。
///
/// 换集：`media = url` → `prepare` → `state = playing`；离开页才 [dispose]。
/// 须在首次使用前调用 [kotvEnsureFvpRegistered]。
class FvpPlayback extends KotvPlayback {
  Player? _player;
  final _posCtrl = StreamController<Duration>.broadcast();
  final _bufCtrl = StreamController<Duration>.broadcast();
  final _doneCtrl = StreamController<bool>.broadcast();
  final List<StreamSubscription> _subs = [];
  Timer? _tick;
  bool _completed = false;
  bool _opening = false;
  bool _live = false;
  bool _buffering = false;
  bool _acceptSize = false;
  int _w = 0;
  int _h = 0;
  String? _lastError;
  String _url = '';
  double _volume = 100;
  double _rate = 1;
  String _decodeMode = 'auto';

  String? get lastError => _lastError;

  void _clearVideoSize() {
    _acceptSize = false;
    _w = 0;
    _h = 0;
  }

  void _adoptSize(int w, int h) {
    if (w <= 0 || h <= 0) return;
    _acceptSize = true;
    _w = w;
    _h = h;
  }

  Player _ensurePlayer() {
    final existing = _player;
    if (existing != null) return existing;
    kotvEnsureFvpRegistered();
    final p = Player();
    _player = p;
    _applyDecodeMode(p);
    p.volume = (_volume / 100).clamp(0.0, 1.0);
    p.playbackRate = _rate;
    _subs.add(p.onMediaStatus.listen((ev) {
      final n = ev.newValue;
      _buffering = n.test(MediaStatus.buffering) || n.test(MediaStatus.loading);
      if (n.test(MediaStatus.loaded) || n.test(MediaStatus.prepared)) {
        unawaited(_syncSizeFromPlayer());
      }
      if (n.test(MediaStatus.end) && !_completed) {
        _completed = true;
        if (!_doneCtrl.isClosed) _doneCtrl.add(true);
      }
      if (n.test(MediaStatus.invalid)) {
        _lastError = 'FVP 媒体无效';
      }
      notifyListeners();
    }));
    _subs.add(p.onStateChanged.listen((_) => notifyListeners()));
    _subs.add(p.onEvent.listen((ev) {
      if (ev.error != 0) {
        _lastError = ev.detail.isNotEmpty ? ev.detail : ev.category;
        notifyListeners();
      }
    }));
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) {
      final pl = _player;
      if (pl == null || _url.isEmpty) return;
      final pos = Duration(milliseconds: pl.position.clamp(0, 1 << 30));
      if (!_posCtrl.isClosed) _posCtrl.add(pos);
      final bufMs = pl.buffered().clamp(0, 1 << 30);
      if (!_bufCtrl.isClosed) {
        _bufCtrl.add(Duration(milliseconds: bufMs));
      }
      if (_opening &&
          (pl.state == PlaybackState.playing ||
              pos > Duration.zero ||
              (_acceptSize && _w > 0))) {
        _opening = false;
        notifyListeners();
      }
    });
    return p;
  }

  Future<void> _syncSizeFromPlayer() async {
    final p = _player;
    if (p == null || _url.isEmpty) return;
    try {
      final size = await p.textureSize.timeout(const Duration(seconds: 2));
      if (size != null && size.width > 0 && size.height > 0) {
        _adoptSize(size.width.toInt(), size.height.toInt());
        notifyListeners();
      }
    } catch (_) {
      try {
        final info = p.mediaInfo;
        final vids = info.video;
        if (vids != null && vids.isNotEmpty) {
          final c = vids.first.codec;
          _adoptSize(c.width, c.height);
          notifyListeners();
        }
      } catch (_) {}
    }
  }

  @override
  bool get playing =>
      _opening ? false : (_player?.state == PlaybackState.playing);

  @override
  bool get completed => _completed;

  @override
  Duration get position {
    final ms = _player?.position ?? 0;
    return Duration(milliseconds: ms.clamp(0, 1 << 30));
  }

  @override
  Duration get duration {
    final ms = _player?.mediaInfo.duration ?? 0;
    if (ms <= 0 || ms >= 0x7fffffff) return Duration.zero;
    return Duration(milliseconds: ms);
  }

  @override
  Duration get buffered {
    final ms = _player?.buffered() ?? 0;
    return Duration(milliseconds: ms.clamp(0, 1 << 30));
  }

  @override
  bool get buffering => _opening || _buffering;

  @override
  double get volume => _volume;

  @override
  double get rate => _rate;

  @override
  int get width => _w;

  @override
  int get height => _h;

  @override
  String get engineLabel => '内置 FVP';

  @override
  Stream<Duration> get positionStream => _posCtrl.stream;

  @override
  Stream<Duration> get bufferedStream => _bufCtrl.stream;

  @override
  Stream<bool> get completedStream => _doneCtrl.stream;

  @override
  List<KotvTrack> get audioTracks => const [];

  @override
  List<KotvTrack> get subtitleTracks => const [];

  @override
  String? get currentAudioId => null;

  @override
  String? get currentSubtitleId => null;

  Widget buildView({BoxFit fit = BoxFit.contain}) {
    final p = _player;
    if (p == null) {
      return const ColoredBox(color: Colors.black);
    }
    final err = _lastError;
    if (err != null && err.isNotEmpty && _w <= 0 && !_opening) {
      return ColoredBox(
        color: Colors.black,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              err,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
        ),
      );
    }
    return ValueListenableBuilder<int?>(
      valueListenable: p.textureId,
      builder: (context, tid, _) {
        final tex = tid ?? -1;
        if (tex < 0) {
          return const ColoredBox(color: Colors.black);
        }
        if (_w <= 0 || _h <= 0) {
          return ColoredBox(
            color: Colors.black,
            child: SizedBox.expand(child: Texture(textureId: tex)),
          );
        }
        return FittedBox(
          fit: fit,
          child: SizedBox(
            width: _w.toDouble(),
            height: _h.toDouble(),
            child: Texture(textureId: tex),
          ),
        );
      },
    );
  }

  @override
  Future<void> open(
    String url, {
    Map<String, String>? headers,
    Map<String, dynamic>? drm,
    bool live = false,
  }) async {
    if (drm != null && '${drm['type'] ?? ''}'.trim().isNotEmpty) {
      throw UnsupportedError('DRM 内容请使用内置 ExoPlayer');
    }
    _opening = true;
    _live = live;
    _lastError = null;
    _completed = false;
    _url = url;
    // 换源清尺寸（对齐 Exo / media_kit MPV）。
    _clearVideoSize();
    notifyListeners();
    try {
      final p = _ensurePlayer();
      // 停播旧片，不 dispose Player（对齐 TV setMediaItem）。
      try {
        p.state = PlaybackState.stopped;
      } catch (_) {}
      final h = kotvNormalizePlayHeaders(headers, url: url);
      if (h.isNotEmpty) {
        final line = StringBuffer();
        h.forEach((k, v) => line.write('$k: $v\r\n'));
        p.setProperty('avio.headers', line.toString());
      } else {
        p.setProperty('avio.headers', '');
      }
      _applyDecodeMode(p);
      try {
        if (live) {
          p.setBufferRange(min: 0, max: 4000, drop: true);
        } else {
          await KotvBufferBudget.warm();
          final maxMs = KotvBufferBudget.fvpMaxBufferMs(KotvBufferBudget.bytes());
          p.setBufferRange(min: 1000, max: maxMs);
        }
      } catch (_) {}
      p.media = url;
      _acceptSize = true;
      notifyListeners();
      final ret = await p.prepare();
      if (ret < 0 && ret != -1) {
        _lastError = 'FVP prepare 失败 ($ret)';
        throw StateError(_lastError!);
      }
      await p.updateTexture();
      await _syncSizeFromPlayer();
      p.volume = (_volume / 100).clamp(0.0, 1.0);
      p.playbackRate = _rate;
      p.state = PlaybackState.playing;
      if (p.state == PlaybackState.playing && _w > 0) {
        _opening = false;
      }
      notifyListeners();
      await _guardSilentVideo();
    } catch (e) {
      _lastError = '$e';
      _opening = false;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> _guardSilentVideo() async {
    final p = _player;
    if (p == null) return;
    await kotvGuardSilentVideo(
      hasVideoSize: () => _w > 0 && _h > 0,
      isBuffering: () => buffering,
      sessionAlive: () {
        if (_url.isEmpty) return false;
        if (_lastError != null) return false;
        return playing || position > Duration.zero;
      },
      isPlaying: () => playing,
      position: () => position,
      duration: () => duration,
      isLiveContent: () => _live || p.isLive || (duration <= Duration.zero && playing),
      hasVideoSource: () => hasVideoSourceHint,
      isAudioOnly: () => isAudioOnlyContent,
      onFixVideoSource: tryFixVideoSource,
    );
    if (_lastError != null) {
      throw StateError(_lastError!);
    }
    _opening = false;
    notifyListeners();
    if (_w <= 0 && _h <= 0 && !isAudioOnlyContent) {
      throw const KotvSilentVideoException();
    }
  }

  @override
  bool get hasVideoSourceHint {
    final p = _player;
    if (p == null) return false;
    if (_lastError != null) return false;
    if (isAudioOnlyContent) return true;
    try {
      final vids = p.mediaInfo.video;
      if (vids != null && vids.isNotEmpty) {
        final active = p.activeVideoTracks;
        return active.isNotEmpty;
      }
    } catch (_) {}
    return _opening || _w > 0;
  }

  @override
  bool get isAudioOnlyContent {
    final p = _player;
    if (p == null || _opening || buffering) return false;
    if (_w > 0 && _h > 0) return false;
    try {
      final info = p.mediaInfo;
      final hasVideo = info.video?.isNotEmpty == true;
      final hasAudio = info.audio?.isNotEmpty == true;
      if (!hasVideo && hasAudio) {
        return playing || position > const Duration(milliseconds: 500);
      }
    } catch (_) {}
    return false;
  }

  @override
  Future<void> tryFixVideoSource() async {
    final p = _player;
    if (p == null) return;
    try {
      final videos = List<VideoStreamInfo>.from(p.mediaInfo.video ?? const []);
      if (videos.isNotEmpty) {
        videos.sort((a, b) {
          final aa = a.codec.width * a.codec.height;
          final bb = b.codec.width * b.codec.height;
          return bb.compareTo(aa);
        });
        for (final stream in videos) {
          try {
            p.activeVideoTracks = [stream.index];
            await Future<void>.delayed(const Duration(milliseconds: 350));
            await _syncSizeFromPlayer();
            if (_w > 0 && _h > 0) return;
          } catch (_) {}
        }
      }
      p.state = PlaybackState.playing;
    } catch (_) {
      try {
        p.state = PlaybackState.playing;
      } catch (_) {}
    }
  }

  @override
  Future<void> playOrPause() async {
    final p = _player;
    if (p == null) return;
    if (p.state == PlaybackState.playing) {
      p.state = PlaybackState.paused;
    } else {
      p.state = PlaybackState.playing;
    }
    notifyListeners();
  }

  @override
  Future<void> play() async {
    _player?.state = PlaybackState.playing;
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    _player?.state = PlaybackState.paused;
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    _opening = false;
    _lastError = null;
    _url = '';
    _clearVideoSize();
    final p = _player;
    if (p != null) {
      try {
        p.state = PlaybackState.stopped;
      } catch (_) {}
      try {
        p.media = '';
      } catch (_) {}
    }
    _buffering = false;
    notifyListeners();
  }

  /// 离开详情：停播并销毁 mdk 实例（对齐 TV engine.release）。
  @override
  Future<void> release() async {
    await stop();
    await _disposePlayer();
  }

  Future<void> _disposePlayer() async {
    _tick?.cancel();
    _tick = null;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    final p = _player;
    _player = null;
    if (p == null) return;
    await kotvTeardownPlayback(
      stop: () async {
        try {
          p.state = PlaybackState.stopped;
        } catch (_) {}
      },
      dispose: () async {
        // mdk Player.dispose 是 async void；包一层避免用 await void。
        try {
          p.dispose();
        } catch (_) {}
        await Future<void>.delayed(const Duration(milliseconds: 50));
      },
      disposeTimeout: const Duration(milliseconds: 600),
    );
  }

  @override
  Future<void> seek(Duration d) async {
    final p = _player;
    if (p == null) return;
    await p.seek(position: d.inMilliseconds);
    notifyListeners();
  }

  @override
  Future<void> setVolume(double v) async {
    _volume = v.clamp(0, 100);
    _player?.volume = (_volume / 100).clamp(0.0, 1.0);
    notifyListeners();
  }

  @override
  Future<void> setRate(double r) async {
    _rate = r.clamp(0.25, 4.0);
    _player?.playbackRate = _rate;
    notifyListeners();
  }

  @override
  Future<void> setRepeatOne(bool on) async {
    try {
      _player?.setProperty('loop', on ? '1' : '0');
    } catch (_) {}
  }

  @override
  Future<void> setDecodeMode(String mode) async {
    final next = switch (mode.trim().toLowerCase()) {
      'soft' || 'software' || 'sw' => 'soft',
      'hard' || 'hardware' || 'hw' => 'hard',
      _ => 'auto',
    };
    _decodeMode = next;
    _applyDecodeMode(_player);
  }

  void _applyDecodeMode(Player? p) {
    if (p == null) return;
    try {
      p.videoDecoders = kotvFvpVideoDecoders(_decodeMode);
    } catch (_) {}
  }

  @override
  Future<void> setAudioTrack(String id) async {}

  @override
  Future<void> setSubtitleTrack(String id) async {}

  @override
  void dispose() {
    unawaited(release());
    unawaited(_posCtrl.close());
    unawaited(_bufCtrl.close());
    unawaited(_doneCtrl.close());
    super.dispose();
  }
}
