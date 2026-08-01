import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'kotv_playback.dart';
import 'kotv_platform.dart';

/// Android ExoPlayer（via video_player / Media3）。
class ExoPlayback extends KotvPlayback {
  ExoPlayback() {
    if (!kotvIsAndroid()) {
      throw UnsupportedError('内置 ExoPlayer 仅支持 Android');
    }
  }

  VideoPlayerController? _c;
  final _posCtrl = StreamController<Duration>.broadcast();
  final _endedCtrl = StreamController<bool>.broadcast();
  Timer? _tick;
  String _url = '';
  bool _playing = false;
  bool _completed = false;
  bool _buffering = false;
  double _volume = 80;
  double _rate = 1;
  int _w = 0;
  int _h = 0;
  bool _repeatOne = false;

  VideoPlayerController? get controller => _c;

  @override
  String get engineLabel => '内置 ExoPlayer';
  @override
  bool get playing => _playing;
  @override
  bool get completed => _completed;
  @override
  Duration get position => _c?.value.position ?? Duration.zero;
  @override
  Duration get duration => _c?.value.duration ?? Duration.zero;
  @override
  double get volume => _volume;
  @override
  double get rate => _rate;
  @override
  int get width => _w;
  @override
  int get height => _h;
  @override
  Stream<Duration> get positionStream => _posCtrl.stream;
  @override
  Stream<bool> get completedStream => _endedCtrl.stream;

  bool get buffering => _buffering;

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

  void _onUpdate() {
    final c = _c;
    if (c == null) return;
    final v = c.value;
    _playing = v.isPlaying;
    _buffering = v.isBuffering;
    _w = v.size.width.toInt();
    _h = v.size.height.toInt();
    if (!_posCtrl.isClosed) _posCtrl.add(v.position);
    if (v.isCompleted && !_completed) {
      _completed = true;
      if (!_endedCtrl.isClosed) _endedCtrl.add(true);
      if (_repeatOne && _url.isNotEmpty) {
        unawaited(open(_url));
      }
    } else if (v.isPlaying) {
      _completed = false;
    }
    notifyListeners();
  }

  @override
  Future<void> open(String url) async {
    _url = url;
    _completed = false;
    final old = _c;
    _c = null;
    old?.removeListener(_onUpdate);
    await old?.dispose();
    final next = VideoPlayerController.networkUrl(Uri.parse(url));
    _c = next;
    next.addListener(_onUpdate);
    await next.initialize();
    await next.setVolume((_volume / 100).clamp(0.0, 1.0));
    await next.setPlaybackSpeed(_rate);
    await next.play();
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(milliseconds: 400), (_) {
      if (_c != null && !_posCtrl.isClosed) {
        _posCtrl.add(_c!.value.position);
        notifyListeners();
      }
    });
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
  }

  @override
  Future<void> play() async => _c?.play();
  @override
  Future<void> pause() async => _c?.pause();
  @override
  Future<void> stop() async {
    await _c?.pause();
    await _c?.seekTo(Duration.zero);
  }

  @override
  Future<void> seek(Duration d) async => _c?.seekTo(d);

  @override
  Future<void> setVolume(double v) async {
    _volume = v.clamp(0, 100);
    await _c?.setVolume((_volume / 100).clamp(0.0, 1.0));
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
    _repeatOne = on;
  }

  @override
  Future<void> setDecodeMode(String mode) async {}

  @override
  List<KotvTrack> get audioTracks => const [];
  @override
  List<KotvTrack> get subtitleTracks => const [];
  @override
  String? get currentAudioId => null;
  @override
  String? get currentSubtitleId => null;
  @override
  Future<void> setAudioTrack(String id) async {}
  @override
  Future<void> setSubtitleTrack(String id) async {}

  @override
  void dispose() {
    _tick?.cancel();
    _c?.removeListener(_onUpdate);
    unawaited(_c?.dispose() ?? Future<void>.value());
    _c = null;
    _posCtrl.close();
    _endedCtrl.close();
    super.dispose();
  }
}
