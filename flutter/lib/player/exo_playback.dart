import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'exo_surface.dart';
import 'kotv_playback.dart';
import 'kotv_platform.dart';
import 'play_headers.dart';
import 'silent_video_guard.dart';

/// Android ExoPlayer：Media3 + OkHttp，DRM；硬解直出到 SurfaceView（对齐 TV HDR）。
class ExoPlayback extends KotvPlayback {
  ExoPlayback() {
    if (!kotvIsAndroid()) {
      throw UnsupportedError('内置 ExoPlayer 仅支持 Android');
    }
  }

  static const _ch = MethodChannel('kotv_exo');
  static const _ev = EventChannel('kotv_exo/events');
  static const _viewType = 'kotv_exo/surface';
  final _viewKey = GlobalKey();

  StreamSubscription? _sub;
  bool _nativeReady = false;
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
  double _pixelRatio = 1;
  /// -1=未知；READY 后由原生写入。用于识别纯音频，避免无画面误切播放器。
  int _videoTrackCount = -1;
  int _audioTrackCount = -1;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffered = Duration.zero;
  int _speedBps = 0;
  bool _repeatOne = false;
  String _decodeMode = 'auto';
  String _renderMode = 'surface';
  bool _live = false;
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
  bool get buffering {
    if (!_buffering) return false;
    // Exo 补缓存时常 STATE_BUFFERING；已在播（含纯音频）不当作起播缓冲，避免浮层/误切。
    if (_playing && (_w > 0 && _h > 0 || _isAudioOnlyUnlocked || _position > const Duration(seconds: 1))) {
      return false;
    }
    return true;
  }
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
    final name = _fitName(fit);
    final surface = kotvExoSurfaceView(
      key: _viewKey,
      viewType: _viewType,
      fitName: name,
      onFit: (fitName) {
        unawaited(_ch.invokeMethod('setFit', {'fit': fitName}).catchError((_) {}));
      },
    );
    // SurfaceView 吃不到 FittedBox 的变换，必须按视频比例给它真实布局尺寸。
    return ColoredBox(
      color: Colors.black,
      child: LayoutBuilder(
        builder: (context, c) {
          final max = c.biggest;
          if (!max.width.isFinite || !max.height.isFinite || max.width <= 0 || max.height <= 0) {
            return surface;
          }
          if (fit == BoxFit.fill || _w <= 0 || _h <= 0) {
            return SizedBox(width: max.width, height: max.height, child: surface);
          }
          final box = _boxFitSize(max, _displaySize, fit);
          final child = SizedBox(width: box.width, height: box.height, child: surface);
          if (fit == BoxFit.cover) {
            return ClipRect(child: Center(child: child));
          }
          return Center(child: child);
        },
      ),
    );
  }

  Size get _displaySize {
    final par = _pixelRatio > 0 ? _pixelRatio : 1.0;
    return Size((_w > 0 ? _w : 16) * par, (_h > 0 ? _h : 9).toDouble());
  }

  static Size _boxFitSize(Size viewport, Size video, BoxFit fit) {
    final ar = video.width / video.height;
    final vr = viewport.width / viewport.height;
    switch (fit) {
      case BoxFit.cover:
        if (ar > vr) return Size(viewport.height * ar, viewport.height);
        return Size(viewport.width, viewport.width / ar);
      default:
        if (ar > vr) return Size(viewport.width, viewport.width / ar);
        return Size(viewport.height * ar, viewport.height);
    }
  }

  static String _fitName(BoxFit fit) {
    switch (fit) {
      case BoxFit.cover:
        return 'cover';
      default:
        return 'contain';
    }
  }

  Future<void> _ensureNative() async {
    if (_nativeReady) return;
    await _ch.invokeMethod('create', {'render': _renderMode});
    _nativeReady = true;
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
        if (m['pixelRatio'] != null) {
          final par = (m['pixelRatio'] as num).toDouble();
          if (par > 0) _pixelRatio = par;
        }
        if (m['durationMs'] != null) {
          _duration = Duration(milliseconds: (m['durationMs'] as num).toInt());
        }
        if (m['videoTrackCount'] != null) {
          _videoTrackCount = (m['videoTrackCount'] as num).toInt();
        }
        if (m['audioTrackCount'] != null) {
          _audioTrackCount = (m['audioTrackCount'] as num).toInt();
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
  Future<void> open(
    String url, {
    Map<String, String>? headers,
    Map<String, dynamic>? drm,
    bool live = false,
  }) async {
    _url = url;
    _live = live;
    _headers = kotvNormalizePlayHeaders(headers, url: url);
    _drm = drm;
    _completed = false;
    _ready = false;
    _lastError = null;
    _videoTrackCount = -1;
    _audioTrackCount = -1;
    _w = 0;
    _h = 0;
    _pixelRatio = 1;
    _position = Duration.zero;
    _duration = Duration.zero;
    _buffered = Duration.zero;
    await _ensureNative();
    try {
      await _ch.invokeMethod('open', {
        'url': url,
        'headers': _headers,
        'mime': _guessMime(url),
        'drm': drm,
        'decodeMode': _decodeMode,
        'render': _renderMode,
        'live': live,
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
      isBuffering: () => !_ready || buffering,
      sessionAlive: () {
        if (_lastError != null) return false;
        return _ready || _playing || _position > Duration.zero;
      },
      isPlaying: () => _playing,
      position: () => _position,
      duration: () => _duration,
      isLiveContent: () =>
          _live || (_ready && _duration <= Duration.zero && _playing),
      hasVideoSource: () => hasVideoSourceHint,
      isAudioOnly: () => isAudioOnlyContent,
      onFixVideoSource: tryFixVideoSource,
    );
    await _refreshTrackCounts();
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

  Future<void> _refreshTrackCounts() async {
    try {
      final v = await _ch.invokeMethod<int>('videoTrackCount');
      final a = await _ch.invokeMethod<int>('audioTrackCount');
      if (v != null) _videoTrackCount = v;
      if (a != null) _audioTrackCount = a;
    } catch (_) {}
  }

  /// 不依赖 buffering 标志：补缓存时仍应识别为纯音频。
  bool get _isAudioOnlyUnlocked {
    if (_lastError != null || !_ready) return false;
    if (_w > 0 && _h > 0) return false;
    if (_videoTrackCount > 0) return false;
    // 明确 0 条视频轨 + 有音轨 → 音乐/电台。
    return _videoTrackCount == 0 && _audioTrackCount > 0;
  }

  @override
  bool get hasVideoSourceHint {
    if (_lastError != null) return false;
    if (isAudioOnlyContent) return true;
    return _ready || _w > 0 || _position > Duration.zero || _playing;
  }

  @override
  bool get isAudioOnlyContent {
    if (!_isAudioOnlyUnlocked) return false;
    return _playing || _position > Duration.zero;
  }

  /// 与 MPV 对齐：按分辨率优先轮询全部视频轨；无轨则 play 软重试。
  @override
  Future<void> tryFixVideoSource() async {
    try {
      await _refreshTrackCounts();
      if (_videoTrackCount == 0) {
        // 纯音频：无需修视源。
        if (_audioTrackCount > 0) return;
        await play();
        return;
      }
      final n = _videoTrackCount > 0
          ? _videoTrackCount
          : (await _ch.invokeMethod<int>('videoTrackCount') ?? 0);
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
  Future<void> setRenderMode(String mode) async {
    _renderMode = kotvNormalizePlayerRender(mode);
    try {
      await _ch.invokeMethod('setRenderMode', {'mode': _renderMode});
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
    _nativeReady = false;
    unawaited(_ch.invokeMethod('dispose').catchError((_) {}));
    _posCtrl.close();
    _bufCtrl.close();
    _endedCtrl.close();
    super.dispose();
  }
}
