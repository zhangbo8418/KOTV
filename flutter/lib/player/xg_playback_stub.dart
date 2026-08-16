import 'package:flutter/material.dart';

import 'kotv_playback.dart';

/// 非 Web：xgplayer 不可用。
class XgPlayback extends KotvPlayback {
  @override
  bool get playing => false;
  @override
  bool get completed => false;
  @override
  Duration get position => Duration.zero;
  @override
  Duration get duration => Duration.zero;
  @override
  double get volume => 100;
  @override
  double get rate => 1;
  @override
  int get width => 0;
  @override
  int get height => 0;
  @override
  String get engineLabel => 'xgplayer';
  @override
  Stream<Duration> get positionStream => const Stream.empty();
  @override
  Stream<bool> get completedStream => const Stream.empty();
  @override
  List<KotvTrack> get audioTracks => const [];
  @override
  List<KotvTrack> get subtitleTracks => const [];
  @override
  String? get currentAudioId => null;
  @override
  String? get currentSubtitleId => null;
  Widget buildView({BoxFit fit = BoxFit.contain}) => const ColoredBox(color: Colors.black);
  @override
  Future<void> open(String url, {Map<String, String>? headers, Map<String, dynamic>? drm}) async {
    throw UnsupportedError('xgplayer 仅支持 Web');
  }

  @override
  Future<void> playOrPause() async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> seek(Duration d) async {}
  @override
  Future<void> setVolume(double v) async {}
  @override
  Future<void> setRate(double r) async {}
  @override
  Future<void> setRepeatOne(bool on) async {}
  @override
  Future<void> setDecodeMode(String mode) async {}
  @override
  Future<void> setAudioTrack(String id) async {}
  @override
  Future<void> setSubtitleTrack(String id) async {}
}
