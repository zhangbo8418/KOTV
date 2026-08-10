import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:video_player/video_player.dart';

import 'fvp_media_url.dart';
import 'kotv_playback.dart';
import 'play_headers.dart';

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
    final c = _c;
    if (c == null || c.value.buffered.isEmpty) return Duration.zero;
    return c.value.buffered.last.end;
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
      // URL 常带 ?id=xxx.m3u8 却实际是 FLV（fengshows）。mdk 若按扩展名走 HLS，
      // prepare 会失败并显示「invalid or unsupported media」。先探魔数再 mdkopt 强制 input。
      final inputFmt = await kotvProbeAvInputFormat(url, headers: h);
      final mediaUrl = kotvFvpMediaUrl(url, inputFormat: inputFmt);
      final c = VideoPlayerController.networkUrl(
        Uri.parse(mediaUrl),
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
        if (v.buffered.isNotEmpty) _bufCtrl.add(v.buffered.last.end);
        if (v.isCompleted && !_completed) {
          _completed = true;
          _doneCtrl.add(true);
        }
        notifyListeners();
      };
      c.addListener(_listener!);
      // 先让父级 rebuild 挂上 VideoPlayer，再 initialize。
      notifyListeners();
      await SchedulerBinding.instance.endOfFrame;
      await Future<void>.delayed(const Duration(milliseconds: 32));
      await c.initialize();
      if (c.value.hasError) {
        _lastError = c.value.errorDescription ?? 'FVP initialize 失败';
        throw StateError(_lastError!);
      }
      await c.setVolume((_volume / 100).clamp(0, 1));
      await c.setPlaybackSpeed(_rate);
      await c.play();
      // 直播可能长时间 size=0：保持 _opening 直到首帧/出尺寸，浮层继续显示。
      if (c.value.isPlaying && c.value.size.width > 0) {
        _opening = false;
      }
      notifyListeners();
    } catch (e) {
      _lastError = '$e';
      _opening = false;
      notifyListeners();
      rethrow;
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
  Future<void> setDecodeMode(String mode) async {}

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
