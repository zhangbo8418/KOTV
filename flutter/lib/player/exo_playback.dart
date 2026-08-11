import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'kotv_playback.dart';
import 'kotv_platform.dart';
import 'play_headers.dart';
import 'silent_video_guard.dart';

/// Android ExoPlayer：Media3 + OkHttp（对齐 TV），DRM；硬解 MediaCodec→Surface 直出。
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
  Map<String, dynamic>? _drm;
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
  Duration _buffered = Duration.zero;
  int _speedBps = 0;
  bool _repeatOne = false;
  String _decodeMode = 'auto';
  String? _lastError;

  final _posCtrl = StreamController<Duration>.broadcast();
  final _bufCtrl = StreamController<Duration>.broadcast();
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
  Duration get buffered => _buffered;
  @override
  bool get buffering => _buffering;
  @override
  int get networkSpeedBps => _speedBps;
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
  Stream<Duration> get bufferedStream => _bufCtrl.stream;
  @override
  Stream<bool> get completedStream => _endedCtrl.stream;

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
        final nextPos = Duration(milliseconds: (m['positionMs'] as num?)?.toInt() ?? 0);
        final nextDur = Duration(milliseconds: (m['durationMs'] as num?)?.toInt() ?? 0);
        final nextBuf = Duration(milliseconds: (m['bufferedMs'] as num?)?.toInt() ?? _buffered.inMilliseconds);
        final nextPlaying = m['playing'] == true;
        final nextBuffering = m['buffering'] == true;
        final nextSpeed = (m['speedBps'] as num?)?.toInt() ?? _speedBps;
        final changed = nextPlaying != _playing ||
            nextBuffering != _buffering ||
            nextSpeed != _speedBps ||
            (nextPos - _position).inMilliseconds.abs() >= 200 ||
            (nextBuf - _buffered).inMilliseconds.abs() >= 500 ||
            nextDur != _duration;
        _position = nextPos;
        _duration = nextDur;
        _buffered = nextBuf;
        _playing = nextPlaying;
        _buffering = nextBuffering;
        _speedBps = nextSpeed < 0 ? 0 : nextSpeed;
        if (!_posCtrl.isClosed) _posCtrl.add(_position);
        if (!_bufCtrl.isClosed) _bufCtrl.add(_buffered);
        if (changed) notifyListeners();
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
          unawaited(open(_url, headers: _headers, drm: _drm));
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

  @override
  Future<void> open(String url, {Map<String, String>? headers, Map<String, dynamic>? drm}) async {
    _url = url;
    _headers = kotvNormalizePlayHeaders(headers, url: url);
    _drm = drm;
    _completed = false;
    _ready = false;
    _lastError = null;
    _position = Duration.zero;
    _duration = Duration.zero;
    _buffered = Duration.zero;
    await _ensureTexture();
    try {
      await _ch.invokeMethod('open', {
        'url': url,
        'headers': _headers,
        'mime': _guessMime(url),
        'drm': drm,
        'decodeMode': _decodeMode,
      });
      await _ch.invokeMethod('setVolume', {'volume': (_volume / 100).clamp(0.0, 1.0)});
      await _ch.invokeMethod('setRate', {'rate': _rate});
    } on PlatformException catch (e) {
      final detail = (e.message ?? e.code).trim();
      throw StateError('Exo 无法播放该地址（$detail）。可换线路或改用其它播放器');
    }
    // 慢源：未 READY 也按缓冲逻辑最多等 60s，避免过早切播放器。
    await kotvGuardSilentVideo(
      hasVideoSize: () => _ready && _w > 0 && _h > 0,
      isBuffering: () => !_ready || _buffering,
      sessionAlive: () {
        if (_lastError != null) return false;
        return _ready || _playing || _position > Duration.zero;
      },
      hasVideoSource: () => hasVideoSourceHint,
      isAudioOnly: () => isAudioOnlyContent,
      onFixVideoSource: tryFixVideoSource,
    );
    if (_lastError != null) {
      throw StateError('Exo 无法播放该地址（$_lastError）。可换线路或改用其它播放器');
    }
    if (!_ready) {
      throw const KotvSilentVideoException('Exo 未就绪');
    }
    if (!(_w > 0 && _h > 0) && !isAudioOnlyContent) {
      throw const KotvSilentVideoException();
    }
    notifyListeners();
  }

  @override
  bool get hasVideoSourceHint {
    if (_lastError != null) return false;
    if (isAudioOnlyContent) return true;
    return _ready || _w > 0 || _position > Duration.zero || _playing;
  }

  @override
  bool get isAudioOnlyContent {
    if (_lastError != null || _buffering || !_ready) return false;
    if (_w > 0 && _h > 0) return false;
    // 仅当原生回报 0 条视频轨时放行；禁止「在播+无尺寸」瞎猜。
    // videoTrackCount 为同步 getter 不便；起播守卫里用轨修复，失败再 failover。
    return false;
  }

  /// 与 MPV 对齐：按分辨率优先轮询全部视频轨；无轨则 play 软重试。
  @override
  Future<void> tryFixVideoSource() async {
    try {
      final n = await _ch.invokeMethod<int>('videoTrackCount') ?? 0;
      if (n <= 0) {
        await play();
        return;
      }
      for (var i = 0; i < n; i++) {
        await _ch.invokeMethod('selectVideoTrack', {'index': i});
        await Future<void>.delayed(const Duration(milliseconds: 350));
        if (_w > 0 && _h > 0) return;
      }
      await play();
    } catch (_) {
      try {
        await play();
      } catch (_) {}
    }
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
  Future<void> setDecodeMode(String mode) async {
    final m = mode.trim().toLowerCase();
    _decodeMode = switch (m) {
      'soft' || 'software' || 'sw' => 'soft',
      'hard' || 'hardware' || 'hw' => 'hard',
      _ => 'auto',
    };
    try {
      await _ch.invokeMethod('setDecodeMode', {'mode': _decodeMode});
    } catch (_) {}
    notifyListeners();
  }

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
    _bufCtrl.close();
    _endedCtrl.close();
    super.dispose();
  }
}
