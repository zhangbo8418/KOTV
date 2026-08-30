import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'kotv_playback.dart';
import 'kotv_platform.dart';
import 'mpv_opts.dart';
import 'mpv_surface.dart';
import 'play_headers.dart';
import 'silent_video_guard.dart';

/// 原生 libmpv 播放后端（对齐 TV `androidx.media3.mpvplayer` + Surface）。
///
/// 不再使用 media_kit / Flutter Texture。
/// - Android：MethodChannel `kotv_mpv` + PlatformView Surface（P1 接 media3-mpvplayer）
/// - 桌面/iOS：同通道，P2 接 FFI/插件
class NativeMpvPlayback extends KotvPlayback {
  NativeMpvPlayback({KotvMpvOpts? opts}) : _opts = opts ?? const KotvMpvOpts();

  static const _ch = MethodChannel('kotv_mpv');
  static const _ev = EventChannel('kotv_mpv/events');

  KotvMpvOpts _opts;
  StreamSubscription? _sub;
  bool _nativeReady = false;
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
  bool _live = false;
  String _url = '';
  Map<String, String> _headers = const {};
  String? _lastError;
  int? _textureId;

  final _posCtrl = StreamController<Duration>.broadcast();
  final _bufCtrl = StreamController<Duration>.broadcast();
  final _endedCtrl = StreamController<bool>.broadcast();

  /// 原位全屏由页面 GlobalKey reparent 同一 PlatformView/Texture，不再 bump 代际。
  int _surfaceGeneration = 0;
  void bumpSurfaceView() {}

  bool get isReady => _ready;

  KotvMpvOpts get opts => _opts;

  String? get lastError => _lastError;

  @override
  String get engineLabel => '内置 MPV';

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
    if (_w > 0 && _h > 0) return false;
    if (_position > const Duration(milliseconds: 300)) return false;
    if (_ready && _playing) return false;
    return true;
  }

  @override
  bool get stalling => buffering;

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

  @override
  List<KotvTrack> get audioTracks => const [];

  @override
  List<KotvTrack> get subtitleTracks => const [];

  @override
  String? get currentAudioId => null;

  @override
  String? get currentSubtitleId => null;

  /// Android：Hybrid Composition SurfaceView（对齐 TV）。
  /// 桌面：原生 libmpv 软件渲染 → Flutter Texture（P2）。
  Widget buildView({BoxFit fit = BoxFit.contain}) {
    if (kotvIsAndroid()) {
      return Stack(
        key: ValueKey('kotv_mpv_surface_$_surfaceGeneration'),
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Colors.black),
          kotvMpvSurfaceView(
            viewType: 'kotv_mpv/surface',
            hybrid: true,
          ),
          if (_lastError != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  _lastError!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.4),
                ),
              ),
            ),
        ],
      );
    }
    if (kotvIsDesktop() && _textureId != null) {
      return Stack(
        key: ValueKey('kotv_mpv_texture_$_surfaceGeneration'),
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Colors.black),
          Center(
            child: Texture(textureId: _textureId!),
          ),
          if (_lastError != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  _lastError!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.4),
                ),
              ),
            ),
        ],
      );
    }
    final err = _lastError;
    return ColoredBox(
      key: ValueKey('kotv_mpv_surface_$_surfaceGeneration'),
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            err ??
                (kotvIsDesktop()
                    ? '桌面 MPV 未就绪\n请运行 scripts/fetch-desktop-mpv-libs.sh\n或 brew install mpv'
                    : 'iOS 原生 MPV（P2）接入中…\n请暂用内置 FVP'),
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.4),
          ),
        ),
      ),
    );
  }

  Future<void> _ensureNative() async {
    if (_nativeReady) return;
    try {
      final res = await _ch.invokeMethod<dynamic>('create', {
        'decode': _opts.hwdecValue(),
        'gpuNext': _opts.gpuNext,
        'vulkan': _opts.vulkan,
        'conf': _opts.conf,
      });
      if (res is Map) {
        final tid = res['textureId'];
        if (tid is int) _textureId = tid;
        if (tid is num) _textureId = tid.toInt();
      }
      await _sub?.cancel();
      _sub = _ev.receiveBroadcastStream().listen(_onEvent, onError: (e) {
        _lastError = '$e';
        notifyListeners();
      });
      _nativeReady = true;
    } catch (e) {
      _lastError = '原生 MPV 通道未就绪: $e';
      _nativeReady = false;
    }
  }

  void _onEvent(dynamic raw) {
    if (raw is String) {
      try {
        raw = jsonDecode(raw);
      } catch (_) {
        return;
      }
    }
    if (raw is! Map) return;
    final m = Map<String, dynamic>.from(raw);
    final event = '${m['event'] ?? ''}';
    switch (event) {
      case 'position':
        _position = Duration(milliseconds: (m['positionMs'] as num?)?.toInt() ?? 0);
        _duration = Duration(milliseconds: (m['durationMs'] as num?)?.toInt() ?? 0);
        _buffered = Duration(milliseconds: (m['bufferedMs'] as num?)?.toInt() ?? _buffered.inMilliseconds);
        _playing = m['playing'] == true;
        _buffering = m['buffering'] == true;
        _speedBps = (m['speedBps'] as num?)?.toInt() ?? 0;
        if (!_posCtrl.isClosed) _posCtrl.add(_position);
        if (!_bufCtrl.isClosed) _bufCtrl.add(_buffered);
        notifyListeners();
        break;
      case 'ready':
      case 'size':
        _w = (m['width'] as num?)?.toInt() ?? _w;
        _h = (m['height'] as num?)?.toInt() ?? _h;
        _ready = true;
        _lastError = null;
        if (_w > 0 && _h > 0) _buffering = false;
        notifyListeners();
        break;
      case 'completed':
        _completed = true;
        _playing = false;
        if (!_endedCtrl.isClosed) _endedCtrl.add(true);
        notifyListeners();
        break;
      case 'error':
        _lastError = '${m['message'] ?? 'MPV error'}';
        _playing = false;
        notifyListeners();
        break;
    }
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
    _completed = false;
    _ready = false;
    _buffering = true;
    _playing = false;
    _w = 0;
    _h = 0;
    _position = Duration.zero;
    _duration = Duration.zero;
    notifyListeners();

    if (drm != null && drm.isNotEmpty) {
      _lastError = 'MPV 不支持 DRM，请用内置 ExoPlayer';
      _buffering = false;
      notifyListeners();
      throw StateError(_lastError!);
    }

    await _ensureNative();
    try {
      await _ch.invokeMethod('open', {
        'url': url,
        'headers': _headers,
        'live': live,
        'decode': _opts.hwdecValue(),
        'gpuNext': _opts.gpuNext,
        'vulkan': _opts.vulkan,
        'conf': _opts.conf,
        'props': _opts.propertyMap(live: live),
      });
    } on MissingPluginException {
      _lastError = kotvIsAndroid()
          ? '原生 MPV 插件未注册'
          : (kotvIsDesktop()
              ? '桌面 MPV 插件未注册（需重新编译 runner）'
              : 'iOS 原生 MPV（P2）尚未接入，请暂用 FVP');
      _buffering = false;
      notifyListeners();
      throw StateError(_lastError!);
    } on PlatformException catch (e) {
      _lastError = (e.message ?? e.code).trim();
      if (_lastError!.isEmpty) _lastError = 'MPV 打开失败';
      _buffering = false;
      notifyListeners();
      throw StateError(_lastError!);
    } catch (e) {
      _lastError = '$e';
      _buffering = false;
      notifyListeners();
      rethrow;
    }

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
      isLiveContent: () => _live || (_ready && _duration <= Duration.zero && _playing),
      onFixVideoSource: tryFixVideoSource,
    );
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
    try {
      await _ch.invokeMethod('play');
      _playing = true;
      notifyListeners();
    } catch (_) {}
  }

  @override
  Future<void> pause() async {
    try {
      await _ch.invokeMethod('pause');
      _playing = false;
      notifyListeners();
    } catch (_) {}
  }

  @override
  Future<void> stop() async {
    try {
      await _ch.invokeMethod('stop');
    } catch (_) {}
    _playing = false;
    _buffering = false;
    _ready = false;
    _url = '';
    notifyListeners();
  }

  @override
  Future<void> seek(Duration d) async {
    try {
      await _ch.invokeMethod('seek', {'positionMs': d.inMilliseconds});
    } catch (_) {}
  }

  @override
  Future<void> setVolume(double v) async {
    _volume = v.clamp(0, 100);
    try {
      await _ch.invokeMethod('setVolume', {'volume': _volume});
    } catch (_) {}
    notifyListeners();
  }

  @override
  Future<void> setRate(double r) async {
    _rate = r;
    try {
      await _ch.invokeMethod('setRate', {'rate': r});
    } catch (_) {}
    notifyListeners();
  }

  @override
  Future<void> setRepeatOne(bool on) async {
    try {
      await _ch.invokeMethod('setRepeatOne', {'on': on});
    } catch (_) {}
  }

  @override
  Future<void> setDecodeMode(String mode) async {
    _opts = _opts.copyWith(decodeMode: mode);
    try {
      await _ch.invokeMethod('setDecode', {'decode': _opts.hwdecValue()});
    } catch (_) {}
  }

  Future<void> applyOpts(KotvMpvOpts opts) async {
    _opts = opts;
    try {
      await _ch.invokeMethod('setOpts', {
        'decode': opts.hwdecValue(),
        'gpuNext': opts.gpuNext,
        'vulkan': opts.vulkan,
        'conf': opts.conf,
        'props': opts.propertyMap(live: _live),
      });
    } catch (_) {}
  }

  Future<void> setStableVolume(bool on) async {
    try {
      await _ch.invokeMethod('setProperty', {
        'key': 'af',
        'value': on ? 'loudnorm' : '',
      });
    } catch (_) {
      try {
        await _ch.invokeMethod('setProperty', {
          'key': 'af',
          'value': on ? 'dynaudnorm' : '',
        });
      } catch (_) {}
    }
  }

  @override
  Future<void> setAudioTrack(String id) async {
    try {
      await _ch.invokeMethod('setAudioTrack', {'id': id});
    } catch (_) {}
  }

  @override
  Future<void> setSubtitleTrack(String id) async {
    try {
      await _ch.invokeMethod('setSubtitleTrack', {'id': id});
    } catch (_) {}
  }

  @override
  Future<void> tryFixVideoSource() async {
    if (_url.isEmpty) return;
    try {
      await _ch.invokeMethod('retryVideo');
    } catch (_) {
      await play();
    }
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel() ?? Future<void>.value());
    _sub = null;
    unawaited(() async {
      try {
        await _ch.invokeMethod('stop');
      } catch (_) {}
      try {
        await _ch.invokeMethod('dispose');
      } catch (_) {}
    }());
    unawaited(_posCtrl.close());
    unawaited(_bufCtrl.close());
    unawaited(_endedCtrl.close());
    super.dispose();
  }
}
