import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import 'kotv_playback.dart';
import 'play_headers.dart';
import 'silent_video_guard.dart';

/// Web 端 JS 播放器种类（Art / 西瓜 / ZW 全能）。
enum KotvWebJsKind { art, xg, zw }

@JS('kotvArt')
external KotvJsPlayerApi get _kotvArt;

@JS('kotvXg')
external KotvJsPlayerApi get _kotvXg;

@JS('kotvZw')
external KotvJsPlayerApi get _kotvZw;

extension type KotvJsPlayerApi._(JSObject _) implements JSObject {
  external bool get ready;
  external String create(web.HTMLDivElement container, String url, JSAny? headers);
  external void destroy(web.HTMLDivElement container);
  external void play(web.HTMLDivElement container);
  external void pause(web.HTMLDivElement container);
  external void seek(web.HTMLDivElement container, double seconds);
  external void setVolume(web.HTMLDivElement container, double v01);
  external void setRate(web.HTMLDivElement container, double rate);
  external void setLoop(web.HTMLDivElement container, bool on);
  external JSObject state(web.HTMLDivElement container);
  external void setObjectFit(web.HTMLDivElement container, String fit);
  external web.HTMLVideoElement? video(web.HTMLDivElement container);
}

var _viewSeq = 0;

double _jsNum(JSObject o, String key) {
  final v = o.getProperty(key.toJS);
  if (v == null) return 0;
  return (v as JSNumber).toDartDouble;
}

bool _jsBool(JSObject o, String key) {
  final v = o.getProperty(key.toJS);
  if (v == null) return false;
  return (v as JSBoolean).toDart;
}

/// Web：统一封装 ArtPlayer / xgplayer / ZWPlayer。
class WebJsPlayback extends KotvPlayback {
  WebJsPlayback(this.kind) {
    _viewType = 'kotv-js-${kind.name}-${_viewSeq++}';
    _container = web.HTMLDivElement();
    _container.style
      ..setProperty('width', '100%')
      ..setProperty('height', '100%')
      ..setProperty('background', '#000')
      ..setProperty('overflow', 'hidden');
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int _) => _container);
  }

  final KotvWebJsKind kind;
  late final String _viewType;
  late final web.HTMLDivElement _container;

  final _posCtrl = StreamController<Duration>.broadcast();
  final _bufCtrl = StreamController<Duration>.broadcast();
  final _doneCtrl = StreamController<bool>.broadcast();
  Timer? _tick;
  bool _completed = false;
  bool _opened = false;
  bool _buffering = false;
  bool _loop = false;
  bool _playing = false;
  double _volume = 100;
  double _rate = 1;
  int _width = 0;
  int _height = 0;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffered = Duration.zero;
  late String _engine = _defaultLabel;
  bool _pipBound = false;
  bool _pipActive = false;
  web.EventListener? _pipEnterListener;
  web.EventListener? _pipLeaveListener;

  KotvJsPlayerApi get _api => switch (kind) {
        KotvWebJsKind.art => _kotvArt,
        KotvWebJsKind.xg => _kotvXg,
        KotvWebJsKind.zw => _kotvZw,
      };

  String get _defaultLabel => switch (kind) {
        KotvWebJsKind.art => 'ArtPlayer',
        KotvWebJsKind.xg => 'xgplayer',
        KotvWebJsKind.zw => 'ZWPlayer',
      };

  @override
  bool get playing => _playing;

  @override
  bool get completed => _completed;

  @override
  Duration get position => _position;

  @override
  Duration get duration => _duration;

  @override
  Duration get buffered => _buffered;

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
  bool get supportsPictureInPicture => web.document.pictureInPictureEnabled;

  @override
  bool get pictureInPictureActive => _pipActive;

  web.HTMLVideoElement? get _video {
    try {
      return _api.video(_container);
    } catch (_) {
      return null;
    }
  }

  void _ensurePipListeners() {
    if (_pipBound) return;
    final v = _video;
    if (v == null) return;
    _pipEnterListener = ((web.Event _) {
      _pipActive = true;
      onPictureInPictureChanged?.call(true);
      notifyListeners();
    }).toJS;
    _pipLeaveListener = ((web.Event _) {
      _pipActive = false;
      onPictureInPictureChanged?.call(false);
      notifyListeners();
    }).toJS;
    v.addEventListener('enterpictureinpicture', _pipEnterListener!);
    v.addEventListener('leavepictureinpicture', _pipLeaveListener!);
    _pipBound = true;
  }

  void _clearPipListeners() {
    final v = _video;
    if (v != null) {
      if (_pipEnterListener != null) {
        v.removeEventListener('enterpictureinpicture', _pipEnterListener!);
      }
      if (_pipLeaveListener != null) {
        v.removeEventListener('leavepictureinpicture', _pipLeaveListener!);
      }
    }
    _pipEnterListener = null;
    _pipLeaveListener = null;
    _pipBound = false;
    _pipActive = false;
  }

  @override
  Future<bool> enterPictureInPicture() async {
    if (!supportsPictureInPicture) return false;
    final v = _video;
    if (v == null) return false;
    _ensurePipListeners();
    try {
      if (web.document.pictureInPictureElement == v) {
        _pipActive = true;
        return true;
      }
      await v.requestPictureInPicture().toDart;
      _pipActive = true;
      onPictureInPictureChanged?.call(true);
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> exitPictureInPicture() async {
    try {
      if (web.document.pictureInPictureElement != null) {
        await web.document.exitPictureInPicture().toDart;
      }
    } catch (_) {}
    _pipActive = false;
    onPictureInPictureChanged?.call(false);
    notifyListeners();
  }

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
    try {
      _api.setObjectFit(_container, objectFit);
    } catch (_) {}
    return ColoredBox(
      color: Colors.black,
      child: HtmlElementView(viewType: _viewType),
    );
  }

  void _pullState() {
    if (!_opened) return;
    try {
      final st = _api.state(_container);
      _playing = _jsBool(st, 'playing');
      _buffering = _jsBool(st, 'buffering');
      _position = Duration(milliseconds: (_jsNum(st, 'currentTime') * 1000).round());
      _duration = Duration(milliseconds: (_jsNum(st, 'duration') * 1000).round());
      _buffered = Duration(milliseconds: (_jsNum(st, 'buffered') * 1000).round());
      final w = _jsNum(st, 'width').round();
      final h = _jsNum(st, 'height').round();
      if (w != _width || h != _height) {
        _width = w;
        _height = h;
      }
      final ended = _jsBool(st, 'ended');
      if (ended && !_completed) {
        _completed = true;
        if (!_doneCtrl.isClosed) _doneCtrl.add(true);
      }
    } catch (_) {}
  }

  @override
  Future<void> open(
    String url, {
    Map<String, String>? headers,
    Map<String, dynamic>? drm,
    bool live = false,
  }) async {
    await stop();
    _completed = false;
    _buffering = true;
    _opened = true;
    _playing = false;
    final h = kotvNormalizePlayHeaders(headers, url: url);
    final hdrJs = h.isEmpty ? null : h.jsify();
    try {
      final mode = _api.create(_container, url, hdrJs);
      _engine = switch (mode) {
        'hls' => '$_defaultLabel·HLS',
        'native' => '$_defaultLabel·HLS',
        _ => _defaultLabel,
      };
    } catch (e) {
      // ignore: avoid_print
      print('$_defaultLabel create failed: $e');
      _engine = _defaultLabel;
    }
    try {
      _api.setVolume(_container, (_volume / 100).clamp(0, 1));
      _api.setRate(_container, _rate);
      _api.setLoop(_container, _loop);
    } catch (_) {}
    _startTick();
    try {
      _api.play(_container);
    } catch (_) {}
    await kotvGuardSilentVideo(
      hasVideoSize: () {
        _pullState();
        return _width > 0 && _height > 0;
      },
      isBuffering: () {
        _pullState();
        return _buffering;
      },
      sessionAlive: () => _opened,
      isPlaying: () {
        _pullState();
        return _playing;
      },
      position: () {
        _pullState();
        return _position;
      },
      duration: () {
        _pullState();
        return _duration;
      },
      isLiveContent: () {
        if (live) return true;
        _pullState();
        return _duration == Duration.zero && _playing;
      },
      hasVideoSource: () => hasVideoSourceHint,
      isAudioOnly: () => isAudioOnlyContent,
      onFixVideoSource: tryFixVideoSource,
    );
    _pullState();
    _buffering = false;
    notifyListeners();
    if (!(_width > 0 && _height > 0) && !isAudioOnlyContent) {
      throw const KotvSilentVideoException();
    }
  }

  @override
  bool get hasVideoSourceHint {
    if (isAudioOnlyContent) return true;
    return _width > 0 || _opened;
  }

  @override
  bool get isAudioOnlyContent {
    if (_buffering) return false;
    return _opened && _width == 0 && _height == 0 && (_playing || _position > const Duration(milliseconds: 500));
  }

  @override
  Future<void> tryFixVideoSource() async {
    try {
      _api.play(_container);
    } catch (_) {}
  }

  void _startTick() {
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!_opened) return;
      _pullState();
      if (!_posCtrl.isClosed) _posCtrl.add(_position);
      if (!_bufCtrl.isClosed) _bufCtrl.add(_buffered);
      notifyListeners();
    });
  }

  @override
  Future<void> playOrPause() async {
    _pullState();
    if (_playing) {
      await pause();
    } else {
      await play();
    }
  }

  @override
  Future<void> play() async {
    try {
      _api.play(_container);
    } catch (_) {}
    _pullState();
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    try {
      _api.pause(_container);
    } catch (_) {}
    _pullState();
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    _tick?.cancel();
    _tick = null;
    _opened = false;
    _buffering = false;
    _playing = false;
    _width = 0;
    _height = 0;
    _position = Duration.zero;
    _duration = Duration.zero;
    _buffered = Duration.zero;
    try {
      await exitPictureInPicture();
    } catch (_) {}
    _clearPipListeners();
    try {
      _api.destroy(_container);
    } catch (_) {}
    notifyListeners();
  }

  @override
  Future<void> seek(Duration d) async {
    try {
      _api.seek(_container, d.inMilliseconds / 1000.0);
    } catch (_) {}
    _pullState();
    notifyListeners();
  }

  @override
  Future<void> setVolume(double v) async {
    _volume = v.clamp(0, 100);
    try {
      _api.setVolume(_container, (_volume / 100).clamp(0, 1));
    } catch (_) {}
    notifyListeners();
  }

  @override
  Future<void> setRate(double r) async {
    _rate = r.clamp(0.25, 4.0);
    try {
      _api.setRate(_container, _rate);
    } catch (_) {}
    notifyListeners();
  }

  @override
  Future<void> setRepeatOne(bool on) async {
    _loop = on;
    try {
      _api.setLoop(_container, on);
    } catch (_) {}
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
