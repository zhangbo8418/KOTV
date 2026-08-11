import 'dart:async';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import 'kotv_playback.dart';
import 'play_headers.dart';
import 'silent_video_guard.dart';

@JS('kotvHls')
external KotvHlsApi get _kotvHls;

/// index.html 注入的 hls.js 胶水。
extension type KotvHlsApi._(JSObject _) implements JSObject {
  external String attach(web.HTMLVideoElement video, String url, JSAny? headers);
  external void destroy(web.HTMLVideoElement video);
  external bool get ready;
}

var _viewSeq = 0;

/// Web：`<video>` + hls.js（Chrome/Firefox）；Safari 原生 HLS。
class HtmlPlayback extends KotvPlayback {
  HtmlPlayback() {
    _viewType = 'kotv-html-video-${_viewSeq++}';
    _video = web.HTMLVideoElement()
      ..autoplay = true
      ..muted = false
      ..controls = false
      ..setAttribute('playsinline', 'true')
      ..setAttribute('webkit-playsinline', 'true');
    _video.style
      ..setProperty('width', '100%')
      ..setProperty('height', '100%')
      ..setProperty('object-fit', 'contain')
      ..setProperty('background', '#000');
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int _) => _video);
  }

  late final String _viewType;
  late final web.HTMLVideoElement _video;

  final _posCtrl = StreamController<Duration>.broadcast();
  final _bufCtrl = StreamController<Duration>.broadcast();
  final _doneCtrl = StreamController<bool>.broadcast();
  Timer? _tick;
  bool _completed = false;
  bool _opened = false;
  bool _buffering = false;
  bool _loop = false;
  double _volume = 100;
  double _rate = 1;
  int _width = 0;
  int _height = 0;
  String _engine = 'HTML5';

  @override
  bool get playing => !_video.paused && !_video.ended;

  @override
  bool get completed => _completed;

  @override
  Duration get position => Duration(milliseconds: (_video.currentTime * 1000).round());

  @override
  Duration get duration {
    final d = _video.duration;
    if (d.isNaN || d.isInfinite || d <= 0) return Duration.zero;
    return Duration(milliseconds: (d * 1000).round());
  }

  @override
  Duration get buffered {
    final b = _video.buffered;
    if (b.length == 0) return Duration.zero;
    final end = b.end(b.length - 1);
    if (end.isNaN) return Duration.zero;
    return Duration(milliseconds: (end * 1000).round());
  }

  @override
  bool get buffering => _buffering;

  @override
  double get volume => _volume;

  @override
  double get rate => _rate;

  @override
  int get width => _width;

  @override
  int get height => _height;

  @override
  String get engineLabel => _engine;

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
    if (!_opened) return const ColoredBox(color: Colors.black);
    final objectFit = switch (fit) {
      BoxFit.cover => 'cover',
      BoxFit.fill => 'fill',
      _ => 'contain',
    };
    _video.style.setProperty('object-fit', objectFit);
    return ColoredBox(
      color: Colors.black,
      child: HtmlElementView(viewType: _viewType),
    );
  }

  @override
  Future<void> open(String url, {Map<String, String>? headers, Map<String, dynamic>? drm}) async {
    await stop();
    _completed = false;
    _buffering = true;
    _opened = true;
    final h = kotvNormalizePlayHeaders(headers, url: url);
    final hdrJs = h.isEmpty ? null : h.jsify();
    try {
      final mode = _kotvHls.attach(_video, url, hdrJs);
      _engine = switch (mode) {
        'hls' => 'hls.js',
        'native' => 'HTML5·HLS',
        _ => 'HTML5',
      };
    } catch (e) {
      // ignore: avoid_print
      print('kotvHls.attach failed: $e');
      _video.src = url;
      _engine = 'HTML5';
    }
    _video.volume = (_volume / 100).clamp(0, 1);
    _video.playbackRate = _rate;
    _video.loop = _loop;
    _wireVideoEvents();
    _startTick();
    try {
      await _video.play().toDart;
    } catch (_) {
      // 自动播放策略可能拒绝；等用户点播放
    }
    await kotvGuardSilentVideo(
      hasVideoSize: () => _video.videoWidth > 0 && _video.videoHeight > 0,
      isBuffering: () => _buffering || _video.readyState < 3,
      sessionAlive: () => !_video.paused || (_video.currentTime > 0) || _opened,
      hasVideoSource: () => hasVideoSourceHint,
      isAudioOnly: () => isAudioOnlyContent,
      onFixVideoSource: tryFixVideoSource,
    );
    _width = _video.videoWidth;
    _height = _video.videoHeight;
    _buffering = false;
    notifyListeners();
  }

  @override
  bool get hasVideoSourceHint {
    if (isAudioOnlyContent) return true;
    try {
      final tracks = _video.videoTracks;
      if (tracks.length > 0) {
        return tracks.selectedIndex >= 0;
      }
    } catch (_) {}
    return _video.readyState >= 1 || _video.videoWidth > 0;
  }

  @override
  bool get isAudioOnlyContent {
    if (_buffering || _video.readyState < 2) return false;
    if (_video.videoWidth > 0 && _video.videoHeight > 0) return false;
    try {
      final vLen = _video.videoTracks.length;
      final aLen = _video.audioTracks.length;
      if (vLen == 0 && aLen > 0) {
        return !_video.paused || _video.currentTime > 0.5;
      }
    } catch (_) {}
    // 轨 API 不可用时不瞎猜。
    return false;
  }

  @override
  Future<void> tryFixVideoSource() async {
    try {
      final tracks = _video.videoTracks;
      final n = tracks.length;
      if (n > 0) {
        for (var i = 0; i < n; i++) {
          for (var j = 0; j < n; j++) {
            tracks[j].selected = j == i;
          }
          await Future<void>.delayed(const Duration(milliseconds: 350));
          if (_video.videoWidth > 0 && _video.videoHeight > 0) {
            await _video.play().toDart;
            return;
          }
        }
      }
    } catch (_) {}
    try {
      await _video.play().toDart;
    } catch (_) {}
  }

  void _wireVideoEvents() {
    _video.onwaiting = ((web.Event _) {
      _buffering = true;
      notifyListeners();
    }).toJS;
    _video.onplaying = ((web.Event _) {
      _buffering = false;
      notifyListeners();
    }).toJS;
    _video.oncanplay = ((web.Event _) {
      _buffering = false;
      notifyListeners();
    }).toJS;
    _video.onended = ((web.Event _) {
      if (!_completed) {
        _completed = true;
        _doneCtrl.add(true);
        notifyListeners();
      }
    }).toJS;
    _video.onloadedmetadata = ((web.Event _) {
      _width = _video.videoWidth;
      _height = _video.videoHeight;
      notifyListeners();
    }).toJS;
    _video.onerror = ((web.Event _) {
      _buffering = false;
      notifyListeners();
    }).toJS;
  }

  void _startTick() {
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!_opened) return;
      if (!_posCtrl.isClosed) _posCtrl.add(position);
      if (!_bufCtrl.isClosed) _bufCtrl.add(buffered);
      final w = _video.videoWidth;
      final h = _video.videoHeight;
      if (w != _width || h != _height) {
        _width = w;
        _height = h;
        notifyListeners();
      }
    });
  }

  @override
  Future<void> playOrPause() async {
    if (_video.paused) {
      await play();
    } else {
      await pause();
    }
  }

  @override
  Future<void> play() async {
    try {
      await _video.play().toDart;
    } catch (_) {}
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    _video.pause();
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    _tick?.cancel();
    _tick = null;
    _opened = false;
    _buffering = false;
    _width = 0;
    _height = 0;
    try {
      _kotvHls.destroy(_video);
    } catch (_) {
      _video.removeAttribute('src');
      _video.load();
    }
    notifyListeners();
  }

  @override
  Future<void> seek(Duration d) async {
    try {
      _video.currentTime = d.inMilliseconds / 1000.0;
    } catch (_) {}
    notifyListeners();
  }

  @override
  Future<void> setVolume(double v) async {
    _volume = v.clamp(0, 100);
    _video.volume = (_volume / 100).clamp(0, 1);
    notifyListeners();
  }

  @override
  Future<void> setRate(double r) async {
    _rate = r.clamp(0.25, 4.0);
    _video.playbackRate = _rate;
    notifyListeners();
  }

  @override
  Future<void> setRepeatOne(bool on) async {
    _loop = on;
    _video.loop = on;
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
