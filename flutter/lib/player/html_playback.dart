import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'kotv_playback.dart';
import 'play_headers.dart';

/// 浏览器 HTML5 / HLS 播放（Flutter Web）。
class HtmlPlayback extends KotvPlayback {
  VideoPlayerController? _c;
  final _posCtrl = StreamController<Duration>.broadcast();
  final _bufCtrl = StreamController<Duration>.broadcast();
  final _doneCtrl = StreamController<bool>.broadcast();
  VoidCallback? _listener;
  bool _completed = false;
  double _volume = 100;
  double _rate = 1;

  VideoPlayerController? get controller => _c;

  @override
  bool get playing => _c?.value.isPlaying ?? false;

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

  @override
  bool get buffering => _c?.value.isBuffering ?? false;

  @override
  double get volume => _volume;

  @override
  double get rate => _rate;

  @override
  int get width => _c?.value.size.width.toInt() ?? 0;

  @override
  int get height => _c?.value.size.height.toInt() ?? 0;

  @override
  String get engineLabel => 'HTML5';

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
    if (c == null || !c.value.isInitialized) {
      return const ColoredBox(color: Colors.black);
    }
    return FittedBox(
      fit: fit,
      child: SizedBox(
        width: c.value.size.width,
        height: c.value.size.height,
        child: VideoPlayer(c),
      ),
    );
  }

  @override
  Future<void> open(String url, {Map<String, String>? headers, Map<String, dynamic>? drm}) async {
    await stop();
    _completed = false;
    final h = kotvNormalizePlayHeaders(headers, url: url);
    final uri = Uri.parse(url);
    final c = VideoPlayerController.networkUrl(uri, httpHeaders: h);
    _c = c;
    _listener = () {
      if (_c != c) return;
      final v = c.value;
      _posCtrl.add(v.position);
      if (v.buffered.isNotEmpty) _bufCtrl.add(v.buffered.last.end);
      if (v.isCompleted && !_completed) {
        _completed = true;
        _doneCtrl.add(true);
      }
      notifyListeners();
    };
    c.addListener(_listener!);
    await c.initialize();
    await c.setVolume((_volume / 100).clamp(0, 1));
    await c.setPlaybackSpeed(_rate);
    await c.play();
    notifyListeners();
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
    final c = _c;
    final l = _listener;
    _c = null;
    _listener = null;
    if (c != null && l != null) c.removeListener(l);
    await c?.dispose();
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
