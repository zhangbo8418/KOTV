import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:fvp/fvp.dart' show FVPControllerExtensions;
import 'package:video_player/video_player.dart';

import 'buffer_budget.dart';
import 'fvp_decoders.dart';
import 'kotv_playback.dart';
import 'play_headers.dart';
import 'silent_video_guard.dart';

/// 页内 FVP（libmdk）：经 [video_player] + fvp 插件。
///
/// 须在 [main] 里先 `registerWith`（见 [kotvRegisterFvp]）。
///
/// 起播顺序：先挂 [VideoPlayer]（建立 Texture/Surface），再 `initialize`/`play`。
class FvpPlayback extends KotvPlayback {
  VideoPlayerController? _c;
  final _posCtrl = StreamController<Duration>.broadcast();
  final _bufCtrl = StreamController<Duration>.broadcast();
  final _doneCtrl = StreamController<bool>.broadcast();
  VoidCallback? _listener;
  bool _completed = false;
  bool _opening = false;
  String? _lastError;
  double _volume = 100;
  double _rate = 1;
  String _decodeMode = 'auto';

  VideoPlayerController? get controller => _c;

  String? get lastError => _lastError;

  @override
  bool get playing => _opening ? false : (_c?.value.isPlaying ?? false);

  @override
  bool get completed => _completed;

  @override
  Duration get position => _c?.value.position ?? Duration.zero;

  @override
  Duration get duration => _c?.value.duration ?? Duration.zero;

  @override
  Duration get buffered {
    final ranges = _c?.value.buffered;
    if (ranges == null || ranges.isEmpty) return Duration.zero;
    var end = Duration.zero;
    for (final r in ranges) {
      if (r.end > end) end = r.end;
    }
    return end;
  }

  /// 起播整段（含 initialize）视为缓冲，避免 `stop()` 清掉标记后浮层消失。
  @override
  bool get buffering => _opening || (_c?.value.isBuffering ?? false);

  @override
  double get volume => _volume;

  @override
  double get rate => _rate;

  @override
  int get width => _c?.value.size.width.toInt() ?? 0;

  @override
  int get height => _c?.value.size.height.toInt() ?? 0;

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
    final c = _c;
    if (c == null) {
      return const ColoredBox(color: Colors.black);
    }
    final err = c.value.errorDescription ?? _lastError;
    if (err != null && err.isNotEmpty && !c.value.isInitialized) {
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
    // 未出尺寸前占满父级，保证 Windows Texture 有非零面积（FittedBox+0x0 会一直黑）。
    final sz = c.value.size;
    if (!c.value.isInitialized || sz.width <= 0 || sz.height <= 0) {
      return ColoredBox(
        color: Colors.black,
        child: SizedBox.expand(child: VideoPlayer(c)),
      );
    }
    return FittedBox(
      fit: fit,
      child: SizedBox(
        width: sz.width,
        height: sz.height,
        child: VideoPlayer(c),
      ),
    );
  }

  Future<void> _disposeController() async {
    final c = _c;
    final l = _listener;
    _c = null;
    _listener = null;
    if (c != null && l != null) c.removeListener(l);
    await c?.dispose();
  }

  @override
  Future<void> open(String url, {Map<String, String>? headers, Map<String, dynamic>? drm}) async {
    if (drm != null && '${drm['type'] ?? ''}'.trim().isNotEmpty) {
      throw UnsupportedError('DRM 内容请使用内置 ExoPlayer');
    }
    _opening = true;
    _lastError = null;
    _completed = false;
    notifyListeners();
    try {
      // 勿调用 stop()：它会把 _opening 清掉，缓冲浮层会立刻消失。
      await _disposeController();
      notifyListeners();
      final h = kotvNormalizePlayHeaders(headers, url: url);
      // 302 交给 mdk 默认 IO 跟跳（未强制 io.avio）。
      final c = VideoPlayerController.networkUrl(
        Uri.parse(url),
        httpHeaders: h,
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );
      _c = c;
      _listener = () {
        if (_c != c) return;
        final v = c.value;
        if (v.hasError) {
          _lastError = v.errorDescription ?? 'FVP 播放错误';
        }
        if (_opening &&
            (v.isPlaying ||
                v.isBuffering ||
                v.position > Duration.zero ||
                (v.isInitialized && v.size.width > 0) ||
                v.isCompleted)) {
          _opening = false;
        }
        _posCtrl.add(v.position);
        if (v.buffered.isNotEmpty) {
          var end = Duration.zero;
          for (final r in v.buffered) {
            if (r.end > end) end = r.end;
          }
          _bufCtrl.add(end);
        }
        if (v.isCompleted && !_completed) {
          _completed = true;
          _doneCtrl.add(true);
        }
        notifyListeners();
      };
      c.addListener(_listener!);
      // initialize 前写入解码器列表（硬/软锁死；自动=硬解优先+软解回退）。
      _applyDecodeMode(c);
      // 先让父级 rebuild 挂上 VideoPlayer，再 initialize。
      notifyListeners();
      await SchedulerBinding.instance.endOfFrame;
      await Future<void>.delayed(const Duration(milliseconds: 32));
      await c.initialize();
      if (c.value.hasError) {
        _lastError = c.value.errorDescription ?? 'FVP initialize 失败';
        throw StateError(_lastError!);
      }
      // MPV：demuxer-max-bytes（内存预算）。mdk 无字节帽，只有 setBufferRange(时间)；
      // 用同一 KotvBufferBudget 换算 maxMs。直播仍短窗+drop。
      try {
        if (c.isLive()) {
          c.setBufferRange(min: 0, max: 4000, drop: true);
        } else {
          await KotvBufferBudget.warm();
          final maxMs = KotvBufferBudget.fvpMaxBufferMs(KotvBufferBudget.bytes());
          c.setBufferRange(min: 1000, max: maxMs);
        }
      } catch (_) {}
      await c.setVolume((_volume / 100).clamp(0, 1));
      await c.setPlaybackSpeed(_rate);
      await c.play();
      // 直播可能长时间 size=0：保持 _opening 直到首帧/出尺寸，浮层继续显示。
      if (c.value.isPlaying && c.value.size.width > 0) {
        _opening = false;
      }
      notifyListeners();
      await _guardSilentVideo(c);
    } catch (e) {
      _lastError = '$e';
      _opening = false;
      notifyListeners();
      rethrow;
    }
  }

  /// 开播后短等出尺寸；仍无画面且会话存活则抛 [KotvSilentVideoException]。
  Future<void> _guardSilentVideo(VideoPlayerController c) async {
    await kotvGuardSilentVideo(
      hasVideoSize: () {
        if (!identical(_c, c)) return true;
        final v = c.value;
        return v.isInitialized && v.size.width > 0 && v.size.height > 0;
      },
      isBuffering: () {
        if (!identical(_c, c)) return false;
        return _opening || c.value.isBuffering;
      },
      sessionAlive: () {
        if (!identical(_c, c)) return false;
        final v = c.value;
        if (v.hasError) return false;
        return v.isPlaying || v.position > Duration.zero;
      },
      hasVideoSource: () {
        if (!identical(_c, c)) return true;
        return hasVideoSourceHint;
      },
      isAudioOnly: () => isAudioOnlyContent,
      onFixVideoSource: tryFixVideoSource,
    );
    if (identical(_c, c) && c.value.hasError) {
      throw StateError(c.value.errorDescription ?? _lastError ?? 'FVP 播放错误');
    }
    if (identical(_c, c)) {
      _opening = false;
      notifyListeners();
    }
  }

  @override
  bool get hasVideoSourceHint {
    final c = _c;
    if (c == null) return false;
    final v = c.value;
    if (v.hasError) return false;
    if (isAudioOnlyContent) return true;
    // Web 上 fvp 的 MediaInfo 是 dummy（无 video/audio）；用 dynamic 避免 dart2js 编译失败。
    try {
      final info = c.getMediaInfo() as dynamic;
      final videos = info?.video as List?;
      if (videos != null && videos.isNotEmpty) {
        final active = c.getActiveVideoTracks() ?? const <int>[];
        // 有视频流但未激活任何轨 → 视源异常，触发重选。
        return active.isNotEmpty;
      }
    } catch (_) {}
    return v.isInitialized || _opening;
  }

  @override
  bool get isAudioOnlyContent {
    final c = _c;
    if (c == null) return false;
    final v = c.value;
    if (!v.isInitialized || v.isBuffering || _opening) return false;
    if (v.size.width > 0 && v.size.height > 0) return false;
    try {
      final info = c.getMediaInfo() as dynamic;
      if (info != null) {
        final hasVideo = (info.video as List?)?.isNotEmpty == true;
        final hasAudio = (info.audio as List?)?.isNotEmpty == true;
        if (hasVideo) return false;
        if (hasAudio) {
          return v.isPlaying || v.position > const Duration(milliseconds: 500);
        }
      }
    } catch (_) {}
    return v.isPlaying || v.position > const Duration(milliseconds: 500);
  }

  @override
  Future<void> tryFixVideoSource() async {
    final c = _c;
    if (c == null) return;
    try {
      final info = c.getMediaInfo() as dynamic;
      final videos = List<dynamic>.from((info?.video as List?) ?? const []);
      if (videos.isNotEmpty) {
        videos.sort((a, b) {
          final aa = (a.codec.width as int) * (a.codec.height as int);
          final bb = (b.codec.width as int) * (b.codec.height as int);
          return bb.compareTo(aa);
        });
        for (final stream in videos) {
          try {
            c.setVideoTracks([stream.index as int]);
            await Future<void>.delayed(const Duration(milliseconds: 350));
            if (!identical(_c, c)) return;
            final sz = c.value.size;
            if (sz.width > 0 && sz.height > 0) return;
          } catch (_) {}
        }
      }
      final programs = info?.programs as List?;
      if (programs != null && programs.length > 1) {
        for (var i = 0; i < programs.length; i++) {
          try {
            c.setProgram(i);
            await Future<void>.delayed(const Duration(milliseconds: 350));
            if (!identical(_c, c)) return;
            final sz = c.value.size;
            if (sz.width > 0 && sz.height > 0) return;
          } catch (_) {}
        }
      }
      await c.play();
    } catch (_) {
      try {
        await c.play();
      } catch (_) {}
    }
  }

  @override
  Future<void> playOrPause() async {
    final c = _c;
    if (c == null) return;
    if (c.value.isPlaying) {
      await c.pause();
    } else {
      await c.play();
    }
    notifyListeners();
  }

  @override
  Future<void> play() async {
    await _c?.play();
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    await _c?.pause();
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    _opening = false;
    _lastError = null;
    await _disposeController();
    notifyListeners();
  }

  @override
  Future<void> seek(Duration d) async {
    await _c?.seekTo(d);
    notifyListeners();
  }

  @override
  Future<void> setVolume(double v) async {
    _volume = v.clamp(0, 100);
    await _c?.setVolume((_volume / 100).clamp(0, 1));
    notifyListeners();
  }

  @override
  Future<void> setRate(double r) async {
    _rate = r.clamp(0.25, 4.0);
    await _c?.setPlaybackSpeed(_rate);
    notifyListeners();
  }

  @override
  Future<void> setRepeatOne(bool on) async {
    await _c?.setLooping(on);
  }

  @override
  Future<void> setDecodeMode(String mode) async {
    final next = switch (mode.trim().toLowerCase()) {
      'soft' || 'software' || 'sw' => 'soft',
      'hard' || 'hardware' || 'hw' => 'hard',
      _ => 'auto',
    };
    if (next == _decodeMode) {
      _applyDecodeMode(_c);
      return;
    }
    _decodeMode = next;
    _applyDecodeMode(_c);
  }

  void _applyDecodeMode(VideoPlayerController? c) {
    if (c == null) return;
    try {
      c.setVideoDecoders(kotvFvpVideoDecoders(_decodeMode));
    } catch (_) {}
  }

  @override
  Future<void> setAudioTrack(String id) async {}

  @override
  Future<void> setSubtitleTrack(String id) async {}

  @override
  void dispose() {
    unawaited(stop());
    _posCtrl.close();
    _bufCtrl.close();
    _doneCtrl.close();
    super.dispose();
  }
}
