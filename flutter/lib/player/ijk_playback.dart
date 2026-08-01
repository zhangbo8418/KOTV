import 'dart:async';

import 'package:fijkplayer/fijkplayer.dart';
import 'package:flutter/material.dart';

import 'kotv_playback.dart';
import 'kotv_platform.dart';

/// Android ijkplayer（via fijkplayer）。
class IjkPlayback extends KotvPlayback {
  IjkPlayback() {
    if (!kotvIsAndroid()) {
      throw UnsupportedError('内置 ijk 仅支持 Android');
    }
    _player = FijkPlayer();
    _player.addListener(_onUpdate);
  }

  late final FijkPlayer _player;
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

  FijkPlayer get player => _player;

  @override
  String get engineLabel => '内置 ijk';
  @override
  bool get playing => _playing;
  @override
  bool get completed => _completed;
  @override
  Duration get position => Duration(milliseconds: _player.currentPos.inMilliseconds);
  @override
  Duration get duration => _player.value.duration;

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
    return FijkView(
      player: _player,
      fit: _mapFit(fit),
      color: Colors.black,
      panelBuilder: (_, __, ___, ____, _____) => const SizedBox.shrink(),
    );
  }

  FijkFit _mapFit(BoxFit fit) {
    switch (fit) {
      case BoxFit.cover:
        return FijkFit.cover;
      case BoxFit.fill:
        return FijkFit.fill;
      case BoxFit.fitWidth:
        return FijkFit.fitWidth;
      case BoxFit.fitHeight:
        return FijkFit.fitHeight;
      default:
        return FijkFit.contain;
    }
  }

  void _onUpdate() {
    final st = _player.state;
    _playing = st == FijkState.started;
    _buffering = st == FijkState.asyncPreparing || _player.isBuffering;
    final size = _player.value.size;
    if (size != null) {
      _w = size.width.toInt();
      _h = size.height.toInt();
    }
    if (!_posCtrl.isClosed) {
      _posCtrl.add(Duration(milliseconds: _player.currentPos.inMilliseconds));
    }
    if (st == FijkState.completed && !_completed) {
      _completed = true;
      if (!_endedCtrl.isClosed) _endedCtrl.add(true);
      if (_repeatOne && _url.isNotEmpty) {
        unawaited(open(_url));
      }
    } else if (_playing) {
      _completed = false;
    }
    notifyListeners();
  }

  @override
  Future<void> open(String url, {Map<String, String>? headers}) async {
    _url = url;
    _completed = false;
    await _player.reset();
    await _player.setDataSource(url, autoPlay: true);
    await _player.setVolume(_volume / 100.0);
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(milliseconds: 400), (_) {
      if (!_posCtrl.isClosed) {
        _posCtrl.add(Duration(milliseconds: _player.currentPos.inMilliseconds));
        notifyListeners();
      }
    });
    notifyListeners();
  }

  @override
  Future<void> playOrPause() async {
    if (_playing) {
      await _player.pause();
    } else {
      await _player.start();
    }
  }

  @override
  Future<void> play() async => _player.start();
  @override
  Future<void> pause() async => _player.pause();
  @override
  Future<void> stop() async => _player.stop();

  @override
  Future<void> seek(Duration d) async => _player.seekTo(d.inMilliseconds);

  @override
  Future<void> setVolume(double v) async {
    _volume = v.clamp(0, 100);
    await _player.setVolume(_volume / 100.0);
    notifyListeners();
  }

  @override
  Future<void> setRate(double r) async {
    _rate = r.clamp(0.25, 4.0);
    await _player.setSpeed(_rate);
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
    _player.removeListener(_onUpdate);
    unawaited(_player.release());
    _posCtrl.close();
    _endedCtrl.close();
    super.dispose();
  }
}
