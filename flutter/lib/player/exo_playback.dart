import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'kotv_playback.dart';
import 'kotv_platform.dart';

/// Android ExoPlayer：走原生 Media3 + OkHttp（对齐 TV），不用 video_player。
class ExoPlayback extends KotvPlayback {
  ExoPlayback() {
    if (!kotvIsAndroid()) {
      throw UnsupportedError('内置 ExoPlayer 仅支持 Android');
    }
  }

  static const _ch = MethodChannel('kotv_exo');
  static const _ev = EventChannel('kotv_exo/events');

  int? _textureId;
  StreamSubscription? _sub;
  String _url = '';
  Map<String, String> _headers = const {};
  bool _playing = false;
  bool _completed = false;
  bool _buffering = false;
  bool _ready = false;
  double _volume = 80;
  double _rate = 1;
  int _w = 0;
  int _h = 0;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _repeatOne = false;
  String? _lastError;

  final _posCtrl = StreamController<Duration>.broadcast();
  final _endedCtrl = StreamController<bool>.broadcast();

  @override
  String get engineLabel => '内置 ExoPlayer';
  @override
  bool get playing => _playing;
  @override
  bool get completed => _completed;
  @override
  Duration get position => _position;
  @override
  Duration get duration => _duration;
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
    final id = _textureId;
    if (id == null || !_ready) {
      return const ColoredBox(color: Colors.black);
    }
    return FittedBox(
      fit: fit,
      child: SizedBox(
        width: (_w > 0 ? _w : 16).toDouble(),
        height: (_h > 0 ? _h : 9).toDouble(),
        child: Texture(textureId: id),
      ),
    );
  }

  Future<void> _ensureTexture() async {
    if (_textureId != null) return;
    final id = await _ch.invokeMethod<int>('create');
    if (id == null) throw StateError('Exo texture create failed');
    _textureId = id;
    await _sub?.cancel();
    _sub = _ev.receiveBroadcastStream().listen(_onEvent, onError: (e) {
      _lastError = '$e';
      notifyListeners();
    });
  }

  void _onEvent(dynamic raw) {
    if (raw is! Map) return;
    final m = Map<String, dynamic>.from(raw);
    final event = '${m['event'] ?? ''}';
    switch (event) {
      case 'position':
        _position = Duration(milliseconds: (m['positionMs'] as num?)?.toInt() ?? 0);
        _duration = Duration(milliseconds: (m['durationMs'] as num?)?.toInt() ?? 0);
        _playing = m['playing'] == true;
        _buffering = m['buffering'] == true;
        if (!_posCtrl.isClosed) _posCtrl.add(_position);
        notifyListeners();
        break;
      case 'ready':
      case 'size':
        _w = (m['width'] as num?)?.toInt() ?? _w;
        _h = (m['height'] as num?)?.toInt() ?? _h;
        if (m['durationMs'] != null) {
          _duration = Duration(milliseconds: (m['durationMs'] as num).toInt());
        }
        _ready = true;
        _lastError = null;
        notifyListeners();
        break;
      case 'completed':
        _completed = true;
        _playing = false;
        if (!_endedCtrl.isClosed) _endedCtrl.add(true);
        if (_repeatOne && _url.isNotEmpty) {
          unawaited(open(_url, headers: _headers));
        }
        notifyListeners();
        break;
      case 'error':
        _lastError = '${m['message'] ?? 'Source error'}';
        _playing = false;
        notifyListeners();
        break;
    }
  }

  static String? _guessMime(String url) {
    final u = url.toLowerCase();
    if (u.contains('.m3u8') || u.contains('m3u8')) return 'application/x-mpegURL';
    if (u.contains('.mpd')) return 'application/dash+xml';
    return null;
  }

  Map<String, String> _mergeHeaders(Map<String, String>? headers) {
    final out = <String, String>{};
    if (headers != null) {
      for (final e in headers.entries) {
        final k = e.key.trim();
        final v = e.value.trim();
        if (k.isEmpty || v.isEmpty) continue;
        out[k] = v;
      }
    }
    return out;
  }

  @override
  Future<void> open(String url, {Map<String, String>? headers}) async {
    _url = url;
    // 对齐 TV：本地 playproxy 已注入远端头；再带 Referer/Cookie 打到 127.0.0.1 会 Source error
    final localProxy = _isLocalProxyUrl(url);
    _headers = localProxy ? const {} : _mergeHeaders(headers);
    _completed = false;
    _ready = false;
    _lastError = null;
    _position = Duration.zero;
    _duration = Duration.zero;
    await _ensureTexture();
    try {
      await _ch.invokeMethod('open', {
        'url': url,
        'headers': _headers,
        'mime': _guessMime(url),
      });
      await _ch.invokeMethod('setVolume', {'volume': (_volume / 100).clamp(0.0, 1.0)});
      await _ch.invokeMethod('setRate', {'rate': _rate});
    } on PlatformException catch (e) {
      final detail = (e.message ?? e.code).trim();
      throw StateError('Exo 无法播放该地址（$detail）。可换线路或改用 ijk/外部播放器');
    }
    // 等 ready / error 一小段，避免 UI 立刻当成功
    for (var i = 0; i < 25; i++) {
      if (_ready) break;
      if (_lastError != null) {
        throw StateError('Exo 无法播放该地址（$_lastError）。可换线路或改用 ijk/外部播放器');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    notifyListeners();
  }

  static bool _isLocalProxyUrl(String url) {
    final u = url.toLowerCase();
    return u.contains('/proxy/play') ||
        u.contains('/proxy/cached_m3u8') ||
        u.contains('/proxy/bt/') ||
        (u.contains('127.0.0.1:') && u.contains('/proxy/'));
  }

  @override
  Future<void> playOrPause() async {
    if (_playing) {
      await pause();
    } else {
      await play();
    }
  }

  @override
  Future<void> play() async {
    await _ch.invokeMethod('play');
    _playing = true;
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    await _ch.invokeMethod('pause');
    _playing = false;
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    await _ch.invokeMethod('stop');
    _playing = false;
    _position = Duration.zero;
    notifyListeners();
  }

  @override
  Future<void> seek(Duration d) async {
    await _ch.invokeMethod('seek', {'positionMs': d.inMilliseconds});
    _position = d;
    notifyListeners();
  }

  @override
  Future<void> setVolume(double v) async {
    _volume = v.clamp(0, 100);
    await _ch.invokeMethod('setVolume', {'volume': (_volume / 100).clamp(0.0, 1.0)});
    notifyListeners();
  }

  @override
  Future<void> setRate(double r) async {
    _rate = r.clamp(0.25, 4.0);
    await _ch.invokeMethod('setRate', {'rate': _rate});
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
    unawaited(_sub?.cancel() ?? Future<void>.value());
    _sub = null;
    unawaited(_ch.invokeMethod('dispose').catchError((_) {}));
    _textureId = null;
    _posCtrl.close();
    _endedCtrl.close();
    super.dispose();
  }
}
