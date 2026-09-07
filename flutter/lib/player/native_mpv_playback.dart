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

/// Android 原生 libmpv（MethodChannel `kotv_mpv` + PlatformView Surface/Texture）。
/// 桌面 / iOS 请用 [MediaKitPlayback]。
class NativeMpvPlayback extends KotvPlayback {
  NativeMpvPlayback({KotvMpvOpts? opts}) : _opts = opts ?? const KotvMpvOpts();

  static const _ch = MethodChannel('kotv_mpv');
  static const _ev = EventChannel('kotv_mpv/events');

  /// 设备宣称 Vulkan≥1.2 时设置页可露出开关。
  static Future<bool> isVulkanAvailable() async {
    if (!kotvIsAndroid()) return false;
    // 优先 MainActivity 通道（不依赖 MPV 插件 attach）。
    try {
      const android = MethodChannel('kotv_android');
      if (await android.invokeMethod<bool>('isVulkanAvailable') == true) {
        return true;
      }
    } catch (_) {}
    try {
      return await _ch.invokeMethod<bool>('isVulkanAvailable') == true;
    } catch (_) {
      return false;
    }
  }

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
  String _renderMode = 'surface';

  final _posCtrl = StreamController<Duration>.broadcast();
  final _bufCtrl = StreamController<Duration>.broadcast();
  final _endedCtrl = StreamController<bool>.broadcast();

  /// 仅随 Texture/错误/就绪变化递增；供详情页 ValueListenableBuilder 重建画面（勿绑 position）。
  final ValueNotifier<int> surfaceRev = ValueNotifier(0);

  /// 原位全屏由页面 GlobalKey reparent 同一 PlatformView/Texture，不再 bump 代际。
  int _surfaceGeneration = 0;
  void bumpSurfaceView() {}

  void _bumpSurface() {
    surfaceRev.value++;
  }

  bool get isReady => _ready;

  /// Android Texture 模式（Surface 模式无 textureId）。
  int? get textureId => _textureId;

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
  /// 浮层网速跟真实缓冲；[buffering] 收紧以免误切。
  bool get stalling => _buffering;

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

  List<KotvTrack> _audioTracks = const [];
  List<KotvTrack> _videoTracks = const [];
  List<KotvTrack> _subtitleTracks = const [];
  String? _currentAudioId;
  String? _currentVideoId;

  @override
  List<KotvTrack> get audioTracks => _audioTracks;

  @override
  List<KotvTrack> get videoTracks => _videoTracks;

  @override
  List<KotvTrack> get subtitleTracks => _subtitleTracks;

  @override
  String? get currentAudioId => _currentAudioId;

  @override
  String? get currentVideoId => _currentVideoId;

  @override
  String? get currentSubtitleId => null;

  Future<void> _refreshAudioTracks() async {
    await _refreshTracks();
  }

  Future<void> _refreshTracks() async {
    if (!_ready || _w <= 0 || _h <= 0) return;
    try {
      final rawA = await _ch.invokeMethod<String>('getAudioTracks');
      final rawV = await _ch.invokeMethod<String>('getVideoTracks');
      if (rawA != null && rawA.isNotEmpty) {
        final list = jsonDecode(rawA) as List<dynamic>;
        _audioTracks = list.map(_mapMpvTrack).toList();
      }
      if (rawV != null && rawV.isNotEmpty) {
        final list = jsonDecode(rawV) as List<dynamic>;
        _videoTracks = list.map(_mapMpvTrack).toList();
      }
      notifyListeners();
    } catch (_) {}
  }

  KotvTrack _mapMpvTrack(dynamic e) {
    final m = Map<String, dynamic>.from(e as Map);
    final id = '${m['id'] ?? ''}'.trim();
    final title = '${m['title'] ?? ''}'.trim();
    final lang = '${m['lang'] ?? ''}'.trim();
    final codec = '${m['codec'] ?? ''}'.trim();
    final w = (m['width'] as num?)?.toInt() ?? 0;
    final h = (m['height'] as num?)?.toInt() ?? 0;
    var label = title.isNotEmpty ? title : (lang.isNotEmpty ? lang : id);
    if (codec.isNotEmpty) label = '$label ($codec)';
    if (w > 0 && h > 0) label = '$label ${w}x$h';
    return KotvTrack(id: id.isEmpty ? 'auto' : id, label: label);
  }

  /// Android：Hybrid Composition SurfaceView / TextureView（对应 setRender）。
  Widget buildView({BoxFit fit = BoxFit.contain}) {
    if (!kotvIsAndroid()) {
      return const ColoredBox(color: Colors.black);
    }
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

  Future<void> _ensureNative() async {
    if (_nativeReady) return;
    try {
      final res = await _ch.invokeMethod<dynamic>('create', {
        'decode': _opts.hwdecValue(),
        'gpuNext': _opts.gpuNext,
        'vulkan': _opts.vulkan,
        'gpuApi': _opts.gpuApi,
        'conf': _opts.conf,
        'render': _renderMode,
      });
      if (res is Map) {
        final tid = res['textureId'];
        if (tid is int) _textureId = tid;
        if (tid is num) _textureId = tid.toInt();
        if (_textureId == null && tid != null) {
          final parsed = int.tryParse('$tid');
          if (parsed != null) _textureId = parsed;
        }
      }
      await _sub?.cancel();
      _sub = _ev.receiveBroadcastStream().listen(_onEvent, onError: (e) {
        _lastError = '$e';
        notifyListeners();
      });
      _nativeReady = true;
      _bumpSurface();
      notifyListeners();
    } catch (e) {
      _nativeReady = false;
      _lastError = '原生 MPV 通道未就绪: $e';
      _bumpSurface();
      notifyListeners();
      rethrow;
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
        break;
      case 'ready':
        final nw = (m['width'] as num?)?.toInt() ?? _w;
        final nh = (m['height'] as num?)?.toInt() ?? _h;
        if (nw > 0) _w = nw;
        if (nh > 0) _h = nh;
        _ready = true;
        _lastError = null;
        if (_w > 0 && _h > 0) _buffering = false;
        unawaited(_refreshAudioTracks());
        _bumpSurface();
        notifyListeners();
        break;
      case 'size':
        final nw = (m['width'] as num?)?.toInt() ?? _w;
        final nh = (m['height'] as num?)?.toInt() ?? _h;
        final sizeChanged = nw != _w || nh != _h;
        if (nw > 0) _w = nw;
        if (nh > 0) _h = nh;
        if (_w > 0 && _h > 0) _buffering = false;
        if (sizeChanged) _bumpSurface();
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
        _bumpSurface();
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
    _bumpSurface();
    notifyListeners();

    if (drm != null && drm.isNotEmpty) {
      _lastError = 'MPV 不支持 DRM，请用内置 ExoPlayer';
      _buffering = false;
      notifyListeners();
      throw StateError(_lastError!);
    }

    await _ensureNative();
    if (!_nativeReady) {
      _buffering = false;
      notifyListeners();
      throw StateError(_lastError ?? '原生 MPV 未就绪');
    }
    try {
      await _ch.invokeMethod('open', {
        'url': url,
        'headers': _headers,
        'live': live,
        'decode': _opts.hwdecValue(),
        'gpuNext': _opts.gpuNext,
        'vulkan': _opts.vulkan,
        'gpuApi': _opts.gpuApi,
        'conf': _opts.conf,
        'render': _renderMode,
        'props': _opts.propertyMap(live: live),
      });
    } on MissingPluginException {
      _lastError = '原生 MPV 插件未注册';
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
  Future<void> release() async {
    await kotvTeardownPlayback(
      stop: () => _ch.invokeMethod('stop'),
      dispose: () => _ch.invokeMethod('dispose'),
    );
    _nativeReady = false;
    _playing = false;
    _buffering = false;
    _ready = false;
    _url = '';
    _textureId = null;
    await _sub?.cancel();
    _sub = null;
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

  @override
  Future<void> setRenderMode(String mode) async {
    _renderMode = kotvNormalizePlayerRender(mode);
    try {
      if (_nativeReady) {
        await _ch.invokeMethod('setRenderMode', {'mode': _renderMode});
      }
    } catch (_) {}
    _bumpSurface();
    notifyListeners();
  }

  Future<void> applyOpts(KotvMpvOpts opts) async {
    _opts = opts;
    try {
      await _ch.invokeMethod('setOpts', {
        'decode': opts.hwdecValue(),
        'gpuNext': opts.gpuNext,
        'vulkan': opts.vulkan,
        'gpuApi': opts.gpuApi,
        'conf': opts.conf,
        'props': opts.propertyMap(live: _live),
      });
    } catch (_) {}
  }

  @override
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
      _currentAudioId = id.isEmpty || id == 'auto' ? null : id;
      notifyListeners();
    } catch (_) {}
  }

  @override
  Future<void> setVideoTrack(String id) async {
    try {
      await _ch.invokeMethod('setVideoTrack', {'id': id});
      _currentVideoId = id.isEmpty || id == 'auto' ? null : id;
      notifyListeners();
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
    surfaceRev.dispose();
    unawaited(_sub?.cancel() ?? Future<void>.value());
    _sub = null;
    // 正常路径已在 [release] 里 await dispose；此处仅兜底（含排空）。
    if (_nativeReady) {
      _nativeReady = false;
      unawaited(
        kotvTeardownPlayback(
          stop: () => _ch.invokeMethod('stop'),
          dispose: () => _ch.invokeMethod('dispose'),
        ),
      );
    }
    unawaited(_posCtrl.close());
    unawaited(_bufCtrl.close());
    unawaited(_endedCtrl.close());
    super.dispose();
  }
}
