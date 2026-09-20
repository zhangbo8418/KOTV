import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'exo_surface.dart';
import 'kotv_playback.dart';
import 'kotv_platform.dart';
import 'play_headers.dart';
import 'silent_video_guard.dart';
import 'subtitle_style_util.dart';
import 'video_eq.dart';

/// Android ExoPlayer：Media3 + OkHttp，DRM；硬解直出到 SurfaceView（HDR 直出）。
class ExoPlayback extends KotvPlayback {
  ExoPlayback() {
    if (!kotvIsAndroid()) {
      throw UnsupportedError('内置 ExoPlayer 仅支持 Android');
    }
  }

  static const _ch = MethodChannel('kotv_exo');
  static const _ev = EventChannel('kotv_exo/events');
  static const _viewType = 'kotv_exo/surface';

  StreamSubscription? _sub;
  bool _nativeReady = false;
  /// Flutter Texture 仅「渲染方式=Texture」兼容模式；默认 SurfaceView 走 PlatformView。
  int? _textureId;
  bool _useFlutterTexture = false;
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
  int _surfaceGeneration = 0;
  /// 默认 Surface：Hybrid SurfaceView，HDR 直出；Texture 为兼容回退（HDR 可能花屏）。
  String _renderMode = 'surface';
  /// 点播挂 SurfaceView / 停播卸下；未点播不建，避免详情滑动重影。
  bool _surfaceLayerEnabled = false;
  /// 后台仅音频：暂时抑制画面层，不改 URL。
  bool _videoOutputSuppressed = false;
  String _videoScale = 'default';
  bool _live = false;
  String? _lastError;
  bool _tunneling = false;
  bool _adblock = true;
  bool _diskCache = false;
  bool _audioPassThrough = true;
  int _dolbyVisionPolicy = 0;
  bool _preferAac = false;
  bool _skipSilence = false;
  bool _softAudioPrefer = false;
  bool _softVideoPrefer = false;
  int _bufferFactor = 1;
  String _preferredTextLangs = '';
  int _diskPreloadMs = 10000;
  int _diskPreloadThreads = 2;
  int _diskPreloadSizeMb = 256;
  bool _libass = true;
  String _secondarySubtitle = 'default';
  String? _currentSecondarySubtitleId;
  double _subtitleFontScale = 1.0;
  double _subtitlePos = 0;
  double _subtitleSecondaryPos = 10;
  String _subtitleColor = '#FFFFFF';
  String _subtitleBorderColor = '#000000';
  double _subtitleBorderSize = 2;
  String _subtitleBgColor = '#00000000';
  String _subtitleEdgeType = 'outline';
  bool _subtitleUseSystemStyle = false;
  bool _subtitleForceStyle = true;
  double _subtitleTextOpacity = 100;
  double _subtitleBgOpacity = 100;
  double _subtitleEdgeOpacity = 100;
  int _subtitleOffsetMs = 0;
  double _subtitleShadowStrength = 50;
  String _subtitleFont = 'default';
  String _subtitleFontPath = '';
  List<Map<String, dynamic>> _subs = const [];
  KotvVideoEq _videoEq = KotvVideoEq.off;
  KotvAudioEqPreset _audioEq = KotvAudioEqPreset.off;
  String _audioEqBands = '';
  int _audioDialogue = 0;
  int _audioBalance = 0;
  int _audioStability = 0;
  int _audioBoost = 0;
  int _audioPreamp = 0;
  bool _audioLoudness = false;
  int _audioCenterGain = 0;
  String _audioChannelMode = 'auto';
  int _audioOffsetMs = 0;
  bool _stableVolumeOn = false;
  bool _previewVideoOriginal = false;
  bool _previewAudioOriginal = false;

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
  bool get repeatOne => _repeatOne;
  @override
  Duration get position => _position;
  @override
  Duration get duration => _duration;
  @override
  Duration get buffered => _buffered;
  @override
  bool get buffering {
    if (!_buffering) return false;
    // Exo 补缓存时常 STATE_BUFFERING；已在播（含纯音频）不当作起播缓冲，避免误切。
    if (_w > 0 && _h > 0) return false;
    if (_position > const Duration(milliseconds: 300)) return false;
    if (_ready && _playing) return false;
    if (_playing && (_isAudioOnlyUnlocked || _position > const Duration(seconds: 1))) {
      return false;
    }
    return true;
  }

  /// 原位全屏不再 bump PlatformView。
  void bumpSurfaceView() {}

  @override
  /// 浮层网速：跟 Exo 真实缓冲态（含拖动后补缓存）；[buffering] 仍收紧以免误切播放器。
  bool get stalling => _buffering;
  @override
  /// SurfaceView + MediaOverlay：原生叠字会被盖住；缓冲/解析走 Flutter 层。
  bool get preferNativeBufferingOverlay => false;
  @override
  Future<void> setNativeBufferingOverlay({required bool visible, required String text}) async {
    if (!preferNativeBufferingOverlay) return;
    try {
      await _ensureNative();
      await _ch.invokeMethod('setBufferingUi', {
        'show': visible,
        'text': text,
      });
    } catch (_) {}
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
    // 播控/设置的比例优先于传入 fit（Surface 路径靠布局 + 原生 setFit）。
    // 画面调色走原生 setVideoEffects（Surface/Texture 共用）；隧道模式不可用。
    final effective = _fitFromScale(_videoScale, fit);
    final tid = _textureId;
    if (_useFlutterTexture) {
      // Texture 兼容模式：create 完成前 tid 可能为空。
      if (tid == null || tid < 0) {
        return const ColoredBox(color: Colors.black);
      }
      return ColoredBox(
        color: Colors.black,
        child: LayoutBuilder(
          builder: (context, c) {
            final max = c.biggest;
            if (!max.width.isFinite || !max.height.isFinite || max.width <= 0 || max.height <= 0) {
              return Texture(textureId: tid);
            }
            if (effective == BoxFit.fill || _w <= 0 || _h <= 0) {
              return SizedBox(
                width: max.width,
                height: max.height,
                child: Texture(textureId: tid),
              );
            }
            final box = _boxFitSize(max, _displaySize, effective);
            final child = SizedBox(
              width: box.width,
              height: box.height,
              child: Texture(textureId: tid),
            );
            if (effective == BoxFit.cover) {
              return ClipRect(child: Center(child: child));
            }
            return Center(child: child);
          },
        ),
      );
    }
    final name = _fitName(effective);
    // Surface：Hybrid Composition + SurfaceView（HDR 直出）。
    final surface = kotvExoSurfaceView(
      key: ValueKey('kotv_exo_surface_$_surfaceGeneration'),
      // 勿用 GlobalKey：全屏进出会挪 PlatformView，易触发 RenderObject.detach 断言。
      viewType: _viewType,
      fitName: name,
      hybrid: true,
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
          if (effective == BoxFit.fill || _w <= 0 || _h <= 0) {
            return SizedBox(width: max.width, height: max.height, child: surface);
          }
          final box = _boxFitSize(max, _displaySize, effective);
          final child = SizedBox(width: box.width, height: box.height, child: surface);
          if (effective == BoxFit.cover) {
            return ClipRect(child: Center(child: child));
          }
          return Center(child: child);
        },
      ),
    );
  }

  static BoxFit _fitFromScale(String scale, BoxFit fallback) {
    switch (scale) {
      case 'fill':
      case '16:9':
      case '4:3':
        return BoxFit.fill;
      case 'zoom':
        return BoxFit.cover;
      case 'default':
        return BoxFit.contain;
      default:
        return fallback;
    }
  }

  @override
  Future<void> setVideoScale(String mode) async {
    final m = mode.trim().isEmpty ? 'default' : mode.trim();
    _videoScale = m;
    final f = _fitFromScale(m, BoxFit.contain);
    try {
      await _ch.invokeMethod('setFit', {'fit': _fitName(f)});
    } catch (_) {}
    notifyListeners();
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
      case BoxFit.fill:
        return 'fill';
      default:
        return 'contain';
    }
  }

  Future<void> _ensureNative() async {
    if (_nativeReady) return;
    final created = await _ch.invokeMethod<dynamic>('create', {'render': _renderMode});
    if (created is Map) {
      final render = '${created['render'] ?? ''}';
      final path = '${created['path'] ?? ''}';
      final tid = (created['textureId'] as num?)?.toInt();
      if (render == 'texture' || render == 'surface') {
        _renderMode = render;
      }
      _applyNativePath(path: path, textureId: tid);
    }
    _nativeReady = true;
    await _sub?.cancel();
    _sub = _ev.receiveBroadcastStream().listen(_onEvent, onError: (e) {
      _lastError = '$e';
      notifyListeners();
    });
  }

  void _applyNativePath({required String path, int? textureId}) {
    if (path == 'flutterTexture' && textureId != null && textureId >= 0) {
      _useFlutterTexture = true;
      _textureId = textureId;
      _renderMode = 'texture';
    } else {
      _useFlutterTexture = false;
      _textureId = null;
    }
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
        unawaited(_refreshTracks());
        break;
      case 'completed':
        _completed = true;
        _playing = false;
        if (_repeatOne && _url.isNotEmpty) {
          // 单集循环：不通知上层切下一集
          unawaited(open(_url, headers: _headers, drm: _drm, live: _live));
        } else if (!_endedCtrl.isClosed) {
          _endedCtrl.add(true);
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
    _audioTracks = const [];
    _videoTracks = const [];
    _subtitleTracks = const [];
    _currentAudioId = null;
    _currentVideoId = null;
    _currentSubtitleId = null;
    _w = 0;
    _h = 0;
    _pixelRatio = 1;
    _position = Duration.zero;
    _duration = Duration.zero;
    _buffered = Duration.zero;
    await _ensureNative();
    // 点播即挂（详情已先挂播控进树）；后台仅音频抑制时不挂。
    await _syncSurfaceLayer();
    try {
      await _ch.invokeMethod('open', {
        'url': url,
        'headers': _headers,
        'mime': _guessMime(url),
        'drm': drm,
        'decodeMode': _decodeMode,
        'render': _renderMode,
        'live': live,
        'tunneling': _tunneling && _renderMode != 'texture',
        'adblock': _adblock,
        'diskCache': _diskCache && !live,
        'audioPassThrough': _audioPassThrough,
        'dolbyVisionPolicy': _dolbyVisionPolicy,
        'preferAac': _preferAac,
        'skipSilence': _skipSilence,
        'softAudioPrefer': _softAudioPrefer,
        'softVideoPrefer': _softVideoPrefer,
        'bufferFactor': _bufferFactor,
        'preferredTextLangs': _preferredTextLangs,
        'diskPreloadMs': (_diskCache && !live) ? _diskPreloadMs : 0,
        'diskPreloadThreads': _diskPreloadThreads,
        'diskPreloadSizeMb': _diskPreloadSizeMb,
        'libass': _libass,
        'secondarySubtitle': _secondarySubtitle,
        'secondarySubtitleId': _currentSecondarySubtitleId ?? '',
        'subtitleFontScale': _subtitleFontScale,
        'subtitlePos': _subtitlePos,
        'subtitleSecondaryPos': _subtitleSecondaryPos,
        'subtitleColor': _subtitleColor,
        'subtitleBorderColor': _subtitleBorderColor,
        'subtitleBorderSize': _subtitleBorderSize,
        'subtitleBgColor': _subtitleBgColor,
        'subtitleEdgeType': _subtitleEdgeType,
        'subtitleUseSystemStyle': _subtitleUseSystemStyle,
        'subtitleForceStyle': _subtitleForceStyle,
        'subtitleTextOpacity': _subtitleTextOpacity,
        'subtitleBgOpacity': _subtitleBgOpacity,
        'subtitleEdgeOpacity': _subtitleEdgeOpacity,
        'subtitleOffsetMs': _subtitleOffsetMs,
        'subtitleShadowStrength': _subtitleShadowStrength,
        'subtitleFont': _subtitleFont,
        'subtitleFontPath': _subtitleFontPath,
        'subs': _subs,
        'audioEq': _previewAudioOriginal ? 'off' : kotvAudioEqExoMode(_audioEq),
        'audioEqBands': _previewAudioOriginal
            ? ''
            : kotvAudioEqExoBandsPayload(
                eq: _audioEq,
                bands: _audioEqBands,
                dialogue: _audioDialogue,
              ),
        'audioDialogue': _previewAudioOriginal ? 0 : _audioDialogue,
        'audioBalance': _previewAudioOriginal ? 0 : _audioBalance,
        'audioStability': _previewAudioOriginal ? 0 : _effectiveAudioStability(),
        'audioBoost': _previewAudioOriginal ? 0 : _audioBoost,
        'audioPreamp': _previewAudioOriginal ? 0 : _audioPreamp,
        'audioLoudness': _previewAudioOriginal ? false : _effectiveAudioLoudness(),
        'audioCenterGain': _previewAudioOriginal ? 0 : _audioCenterGain,
        'audioChannelMode': _previewAudioOriginal ? 'auto' : _audioChannelMode,
        'audioOffsetMs': _audioOffsetMs,
        'eqBrightness': (_videoEq.enabled && !_previewVideoOriginal) ? _videoEq.brightness : 0,
        'eqContrast': (_videoEq.enabled && !_previewVideoOriginal) ? _videoEq.contrast : 0,
        'eqSaturation': (_videoEq.enabled && !_previewVideoOriginal) ? _videoEq.saturation : 0,
        'eqGamma': (_videoEq.enabled && !_previewVideoOriginal) ? _videoEq.gamma : 0,
        'eqHue': (_videoEq.enabled && !_previewVideoOriginal) ? _videoEq.hue : 0,
        'eqTemperature': (_videoEq.enabled && !_previewVideoOriginal) ? _videoEq.temperature : 0,
        'eqSharpness': (_videoEq.enabled && !_previewVideoOriginal) ? _videoEq.sharpness : 0,
        'eqShadow': (_videoEq.enabled && !_previewVideoOriginal) ? _videoEq.shadow : 0,
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
    _appliedColdPlayerOptsKey = _coldPlayerOptsKey();
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

  /// 与 MPV 保持一致：按分辨率优先轮询全部视频轨；无轨则 play 软重试。
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
    // 换集/停播只 stop，会话内复用 Exo 实例（离开页走 [release]）。
    try {
      await _ch.invokeMethod('stop');
    } catch (_) {}
    _playing = false;
    _position = Duration.zero;
    _ready = false;
    _url = '';
    _w = 0;
    _h = 0;
    await _setSurfaceLayerEnabled(false);
    notifyListeners();
  }

  @override
  Future<void> stopForEpisodeSwitch() async {
    try {
      await _ch.invokeMethod('stop');
    } catch (_) {}
    _playing = false;
    _position = Duration.zero;
    _ready = false;
    _url = '';
    _w = 0;
    _h = 0;
    // 换集保留 SurfaceView，避免卸面闪底层。
    notifyListeners();
  }

  @override
  Future<void> release() async {
    // stop → 短排空 → dispose（超时丢后台，避免卡死返回）。
    await kotvTeardownPlayback(
      stop: () async {
        try {
          await _ch.invokeMethod('stop');
        } catch (_) {}
      },
      dispose: () async {
        try {
          await _ch.invokeMethod('dispose');
        } catch (_) {}
      },
      drain: const Duration(milliseconds: 400),
      disposeTimeout: const Duration(milliseconds: 600),
    );
    _nativeReady = false;
    _playing = false;
    _position = Duration.zero;
    _ready = false;
    _url = '';
    _w = 0;
    _h = 0;
    _textureId = null;
    _useFlutterTexture = false;
    _surfaceLayerEnabled = false;
    await _sub?.cancel();
    _sub = null;
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
    final next = kotvNormalizePlayerRender(mode);
    _renderMode = next;
    try {
      await _ensureNative();
      final raw = await _ch.invokeMethod<dynamic>('setRenderMode', {'mode': _renderMode});
      if (raw is Map) {
        final path = '${raw['path'] ?? ''}';
        final tid = (raw['textureId'] as num?)?.toInt();
        final render = '${raw['render'] ?? ''}';
        if (render == 'texture' || render == 'surface') _renderMode = render;
        _applyNativePath(path: path, textureId: tid);
      }
      // 强制换 PlatformView / Texture 子树，避免全屏 Stable 层仍挂旧面导致定格。
      _surfaceGeneration++;
      await _syncSurfaceLayer();
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _syncSurfaceLayer() async {
    // 有点播 URL 就挂；后台仅音频时可暂时抑制。
    await _setSurfaceLayerEnabled(_url.isNotEmpty && !_videoOutputSuppressed);
  }

  @override
  Future<void> setVideoOutputEnabled(bool enabled) async {
    _videoOutputSuppressed = !enabled;
    await _syncSurfaceLayer();
  }

  Future<void> _setSurfaceLayerEnabled(bool enabled) async {
    if (_useFlutterTexture) {
      _surfaceLayerEnabled = enabled;
      return;
    }
    if (_surfaceLayerEnabled == enabled) {
      if (enabled) {
        try {
          await _ensureNative();
          await _ch.invokeMethod('setSurfaceLayerEnabled', {'enabled': true});
        } catch (_) {}
      }
      return;
    }
    _surfaceLayerEnabled = enabled;
    try {
      await _ensureNative();
      await _ch.invokeMethod('setSurfaceLayerEnabled', {'enabled': enabled});
    } catch (_) {}
  }

  List<KotvTrack> _audioTracks = const [];
  List<KotvTrack> _videoTracks = const [];
  List<KotvTrack> _subtitleTracks = const [];
  String? _currentAudioId;
  String? _currentVideoId;
  String? _currentSubtitleId;

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
  String? get currentSubtitleId => _currentSubtitleId;

  @override
  String? get currentSecondarySubtitleId => _currentSecondarySubtitleId;

  Future<void> _refreshTracks() async {
    if (!_nativeReady) return;
    try {
      final a = await _ch.invokeMethod<dynamic>('getAudioTracks');
      final v = await _ch.invokeMethod<dynamic>('getVideoTracks');
      final s = await _ch.invokeMethod<dynamic>('getSubtitleTracks');
      _audioTracks = _parseTrackList(a);
      _videoTracks = _parseTrackList(v);
      _subtitleTracks = _parseTrackList(s);
      _currentAudioId = null;
      _currentVideoId = null;
      _currentSubtitleId = null;
      if (a is List) {
        for (final e in a) {
          if (e is Map && e['selected'] == true) {
            _currentAudioId = '${e['id'] ?? ''}';
            break;
          }
        }
      }
      if (v is List) {
        for (final e in v) {
          if (e is Map && e['selected'] == true) {
            _currentVideoId = '${e['id'] ?? ''}';
            break;
          }
        }
      }
      if (s is List) {
        for (final e in s) {
          if (e is Map && e['selected'] == true) {
            _currentSubtitleId = '${e['id'] ?? ''}';
            break;
          }
        }
      }
      notifyListeners();
    } catch (_) {}
  }

  List<KotvTrack> _parseTrackList(dynamic raw) {
    if (raw is! List) return const [];
    return raw.map((e) {
      if (e is! Map) return null;
      final id = '${e['id'] ?? ''}'.trim();
      if (id.isEmpty) return null;
      final label = '${e['label'] ?? id}'.trim();
      return KotvTrack(id: id, label: label.isEmpty ? id : label);
    }).whereType<KotvTrack>().toList();
  }

  @override
  Future<void> setAudioTrack(String id) async {
    try {
      await _ensureNative();
      await _ch.invokeMethod('selectAudioTrack', {'id': id});
      _currentAudioId = id;
      await _refreshTracks();
    } catch (_) {}
  }

  @override
  Future<void> setVideoTrack(String id) async {
    try {
      await _ensureNative();
      await _ch.invokeMethod('selectVideoTrack', {'id': id});
      _currentVideoId = id;
      await _refreshTracks();
    } catch (_) {}
  }

  @override
  Future<void> setSubtitleTrack(String id) async {
    try {
      await _ensureNative();
      await _ch.invokeMethod('selectSubtitleTrack', {'id': id});
      final key = id.trim().toLowerCase();
      _currentSubtitleId = (key.isEmpty || key == 'no' || key == 'off' || key == 'auto') ? null : id;
      await _refreshTracks();
    } catch (_) {}
  }

  /// 从设置页写入：隧道 / 去广告 / 磁盘缓存 / 直通 / DV / AAC / 跳过静音。
  void applyPlayerOptions(Map<String, dynamic> settings) {
    _tunneling = kotvSettingsMapFlag(settings, 'exoTunneling', def: false);
    _adblock = kotvSettingsMapFlag(settings, 'exoAdblock', def: true);
    _diskCache = kotvSettingsMapFlag(settings, 'exoDiskCache', def: false);
    _audioPassThrough = kotvSettingsMapFlag(settings, 'audioPassThrough', def: true);
    _preferAac = kotvSettingsMapFlag(settings, 'exoPreferAac', def: false);
    _skipSilence = kotvSettingsMapFlag(settings, 'exoSkipSilence', def: false);
    _softAudioPrefer = kotvSettingsMapFlag(settings, 'exoSoftAudioPrefer', def: false);
    _softVideoPrefer = kotvSettingsMapFlag(settings, 'exoSoftVideoPrefer', def: false);
    _bufferFactor = int.tryParse('${settings['exoBuffer'] ?? '1'}') ?? 1;
    if (_bufferFactor < 1) _bufferFactor = 1;
    if (_bufferFactor > 10) _bufferFactor = 10;
    _libass = kotvSettingsMapFlag(settings, 'exoLibass', def: true);
    _dolbyVisionPolicy = int.tryParse('${settings['exoDolbyVision'] ?? '0'}') ?? 0;
    _preferredTextLangs = '${settings['exoPreferredTextLangs'] ?? ''}'.trim();
    _diskPreloadMs = int.tryParse('${settings['exoDiskPreloadMs'] ?? '10000'}') ?? 10000;
    if (_diskPreloadMs < 0) _diskPreloadMs = 0;
    if (_diskPreloadMs > 120000) _diskPreloadMs = 120000;
    _diskPreloadThreads = int.tryParse('${settings['exoDiskPreloadThreads'] ?? '2'}') ?? 2;
    if (_diskPreloadThreads < 1) _diskPreloadThreads = 1;
    if (_diskPreloadThreads > 10) _diskPreloadThreads = 10;
    _diskPreloadSizeMb = int.tryParse('${settings['exoDiskPreloadSizeMb'] ?? '256'}') ?? 256;
    if (_diskPreloadSizeMb < 128) _diskPreloadSizeMb = 128;
    if (_diskPreloadSizeMb > 4096) _diskPreloadSizeMb = 4096;
    final sec = '${settings['exoSecondarySubtitle'] ?? 'default'}'.trim().toLowerCase();
    _secondarySubtitle = (sec == 'auto' || sec == 'on' || sec == 'manual' || sec == 'default' || sec == 'player')
        ? (sec == 'on' ? 'auto' : (sec == 'player' ? 'default' : sec))
        : 'default';
    _subtitleFontScale = double.tryParse('${settings['subtitleFontScale'] ?? '1.0'}') ?? 1.0;
    _subtitlePos = kotvSubtitlePosFromSettings(settings['subtitlePos']);
    _subtitleSecondaryPos =
        (double.tryParse('${settings['subtitleSecondaryPos'] ?? '10'}') ?? 10).clamp(0, 150);
    _subtitleColor = '${settings['subtitleColor'] ?? '#FFFFFF'}'.trim();
    if (_subtitleColor.isEmpty) _subtitleColor = '#FFFFFF';
    _subtitleBorderColor = '${settings['subtitleBorderColor'] ?? '#000000'}'.trim();
    if (_subtitleBorderColor.isEmpty) _subtitleBorderColor = '#000000';
    _subtitleBorderSize =
        (double.tryParse('${settings['subtitleBorderSize'] ?? '2'}') ?? 2).clamp(0, 8);
    _subtitleBgColor = '${settings['subtitleBgColor'] ?? '#00000000'}'.trim();
    if (_subtitleBgColor.isEmpty) _subtitleBgColor = '#00000000';
    final edge = '${settings['subtitleEdgeType'] ?? 'outline'}'.trim().toLowerCase();
    _subtitleEdgeType = kotvNormalizeSubtitleEdgeType(edge);
    final styleMode = '${settings['subtitleStyleMode'] ?? 'custom'}'.trim().toLowerCase();
    _subtitleUseSystemStyle = styleMode == 'system';
    _subtitleForceStyle = styleMode == 'custom';
    _subtitleTextOpacity =
        (double.tryParse('${settings['subtitleTextOpacity'] ?? '100'}') ?? 100).clamp(0, 100);
    _subtitleBgOpacity =
        (double.tryParse('${settings['subtitleBgOpacity'] ?? '100'}') ?? 100).clamp(0, 100);
    _subtitleEdgeOpacity =
        (double.tryParse('${settings['subtitleEdgeOpacity'] ?? '100'}') ?? 100).clamp(0, 100);
    _subtitleOffsetMs = int.tryParse('${settings['subtitleOffsetMs'] ?? '0'}') ?? 0;
    if (_subtitleOffsetMs < -300000) _subtitleOffsetMs = -300000;
    if (_subtitleOffsetMs > 300000) _subtitleOffsetMs = 300000;
    _subtitleShadowStrength = kotvSubtitleShadowStrength('${settings['subtitleShadowStrength'] ?? '50'}');
    _subtitleFont = kotvNormalizeSubtitleFont('${settings['subtitleFont'] ?? 'default'}');
    _subtitleFontPath = '${settings['subtitleFontPath'] ?? ''}'.trim();
    _videoEq = KotvVideoEq.fromSettings(settings);
    _audioEq = kotvAudioEqFromSettings(settings);
    _audioEqBands = kotvAudioEqBandsFromSettings(settings);
    _audioDialogue = kotvAudioDialogueFromSettings(settings);
    _audioBalance = kotvAudioBalanceFromSettings(settings);
    _audioStability = kotvAudioStabilityFromSettings(settings);
    _audioBoost = kotvAudioBoostFromSettings(settings);
    _audioPreamp = kotvAudioPreampFromSettings(settings);
    _audioLoudness = kotvAudioLoudnessFromSettings(settings);
    _stableVolumeOn = kotvSettingsMapFlag(settings, 'playerStableVolume', def: false);
    _audioCenterGain = kotvAudioCenterGainFromSettings(settings);
    _audioChannelMode = kotvAudioChannelModeFromSettings(settings);
    _audioOffsetMs = kotvAudioOffsetMsFromSettings(settings);
    if (_url.isNotEmpty) {
      unawaited(_pushEqualizer());
      final custom = _subtitleForceStyle;
      unawaited(setSubtitleStyle(
        scale: _subtitleFontScale,
        pos: _subtitlePos,
        secondaryPos: _subtitleSecondaryPos,
        color: custom ? _subtitleColor : null,
        borderColor: custom ? _subtitleBorderColor : null,
        borderSize: custom ? _subtitleBorderSize : null,
        bgColor: custom ? _subtitleBgColor : null,
        edgeType: custom ? _subtitleEdgeType : null,
        useSystemStyle: _subtitleUseSystemStyle,
        textOpacity: custom || _subtitleUseSystemStyle ? _subtitleTextOpacity : null,
        bgOpacity: custom || _subtitleUseSystemStyle ? _subtitleBgOpacity : null,
        edgeOpacity: custom || _subtitleUseSystemStyle ? _subtitleEdgeOpacity : null,
        shadowStrength: custom || _subtitleUseSystemStyle ? _subtitleShadowStrength : null,
        font: custom || _subtitleUseSystemStyle ? _subtitleFont : null,
        fontPath: custom || _subtitleUseSystemStyle ? _subtitleFontPath : null,
        forceStyle: custom,
      ));
      unawaited(setSubtitleOffsetMs(_subtitleOffsetMs));
      unawaited(_syncRuntimePlayerOptions());
    }
  }

  String _coldPlayerOptsKey() =>
      '$_tunneling|$_adblock|$_diskCache|$_audioPassThrough|'
      '$_softAudioPrefer|$_softVideoPrefer|$_bufferFactor|$_libass|'
      '$_dolbyVisionPolicy|$_secondarySubtitle|$_diskPreloadMs|'
      '$_diskPreloadThreads|$_diskPreloadSizeMb';

  String? _appliedColdPlayerOptsKey;

  /// 跳静音可热设；缓冲/隧道/libass 等冷选项变化则同 URL 重开。
  Future<void> _syncRuntimePlayerOptions() async {
    try {
      await _ensureNative();
      try {
        await _ch.invokeMethod('setSkipSilence', {'enabled': _skipSilence});
      } catch (_) {}
      try {
        await _ch.invokeMethod('setPreferAac', {'enabled': _preferAac});
      } catch (_) {}
      final cold = _coldPlayerOptsKey();
      if (_appliedColdPlayerOptsKey != null && cold != _appliedColdPlayerOptsKey) {
        if (_url.isNotEmpty) {
          await open(_url, headers: _headers, drm: _drm, live: _live);
        }
      }
    } catch (_) {}
  }

  int _effectiveAudioStability() =>
      _stableVolumeOn ? (_audioStability > 0 ? _audioStability : 55) : _audioStability;

  bool _effectiveAudioLoudness() => _stableVolumeOn || _audioLoudness;

  @override
  Future<void> setStableVolume(bool on) async {
    _stableVolumeOn = on;
    // 起播前可能尚未 open，仍记下偏好；已就绪则立刻推效果。
    if (_nativeReady && _url.isNotEmpty) {
      await _pushEqualizer();
    }
  }

  Future<void> _pushEqualizer() async {
    try {
      await _ensureNative();
      final videoOn = _videoEq.enabled && !_previewVideoOriginal;
      final audioPass = _audioPassThrough;
      await _ch.invokeMethod('setEqualizer', {
        'audioEq': _previewAudioOriginal ? 'off' : kotvAudioEqExoMode(_audioEq),
        'audioEqBands': _previewAudioOriginal
            ? ''
            : kotvAudioEqExoBandsPayload(
                eq: _audioEq,
                bands: _audioEqBands,
                dialogue: _audioDialogue,
              ),
        'audioDialogue': _previewAudioOriginal ? 0 : _audioDialogue,
        'audioBalance': _previewAudioOriginal ? 0 : _audioBalance,
        'audioStability': _previewAudioOriginal ? 0 : _effectiveAudioStability(),
        'audioBoost': _previewAudioOriginal ? 0 : _audioBoost,
        'audioPreamp': _previewAudioOriginal ? 0 : _audioPreamp,
        'audioLoudness': _previewAudioOriginal ? false : _effectiveAudioLoudness(),
        'audioCenterGain': _previewAudioOriginal ? 0 : _audioCenterGain,
        'audioChannelMode': _previewAudioOriginal ? 'auto' : _audioChannelMode,
        'audioOffsetMs': _audioOffsetMs,
        'eqBrightness': videoOn ? _videoEq.brightness : 0,
        'eqContrast': videoOn ? _videoEq.contrast : 0,
        'eqSaturation': videoOn ? _videoEq.saturation : 0,
        'eqGamma': videoOn ? _videoEq.gamma : 0,
        'eqHue': videoOn ? _videoEq.hue : 0,
        'eqTemperature': videoOn ? _videoEq.temperature : 0,
        'eqSharpness': videoOn ? _videoEq.sharpness : 0,
        'eqShadow': videoOn ? _videoEq.shadow : 0,
        'audioPassThrough': audioPass,
      });
      notifyListeners();
    } catch (_) {}
  }

  @override
  Future<void> setFxPreview({bool? videoOriginal, bool? audioOriginal}) async {
    if (videoOriginal != null) _previewVideoOriginal = videoOriginal;
    if (audioOriginal != null) _previewAudioOriginal = audioOriginal;
    if (_nativeReady && _url.isNotEmpty) {
      await _pushEqualizer();
    }
  }

  @override
  Future<List<int>> queryAudioEqCenters() async {
    try {
      await _ensureNative();
      final raw = await _ch.invokeMethod<dynamic>('getEqualizerCenters');
      if (raw is List) {
        return raw.map((e) => (e as num).toInt()).where((hz) => hz > 0).toList();
      }
    } catch (_) {}
    return const [60, 230, 910, 3600, 14000];
  }

  @override
  Future<void> setSubtitleStyle({
    double? scale,
    double? pos,
    double? secondaryPos,
    bool forceStyle = false,
    String? color,
    String? borderColor,
    double? borderSize,
    String? bgColor,
    String? edgeType,
    bool useSystemStyle = false,
    double? textOpacity,
    double? bgOpacity,
    double? edgeOpacity,
    double? shadowStrength,
    String? font,
    String? fontPath,
  }) async {
    if (scale != null) _subtitleFontScale = scale.clamp(0.5, 2.5);
    if (pos != null) _subtitlePos = pos.clamp(-20, 30);
    if (secondaryPos != null) _subtitleSecondaryPos = secondaryPos.clamp(0, 150);
    if (color != null && color.trim().isNotEmpty) _subtitleColor = color.trim();
    if (borderColor != null && borderColor.trim().isNotEmpty) {
      _subtitleBorderColor = borderColor.trim();
    }
    if (borderSize != null) _subtitleBorderSize = borderSize.clamp(0, 8);
    if (bgColor != null && bgColor.trim().isNotEmpty) _subtitleBgColor = bgColor.trim();
    if (edgeType != null && edgeType.trim().isNotEmpty) {
      _subtitleEdgeType = kotvNormalizeSubtitleEdgeType(edgeType);
    }
    if (textOpacity != null) _subtitleTextOpacity = textOpacity.clamp(0, 100);
    if (bgOpacity != null) _subtitleBgOpacity = bgOpacity.clamp(0, 100);
    if (edgeOpacity != null) _subtitleEdgeOpacity = edgeOpacity.clamp(0, 100);
    if (shadowStrength != null) _subtitleShadowStrength = shadowStrength.clamp(0, 100);
    if (font != null) _subtitleFont = kotvNormalizeSubtitleFont(font);
    if (fontPath != null) _subtitleFontPath = fontPath.trim();
    _subtitleUseSystemStyle = useSystemStyle;
    _subtitleForceStyle = forceStyle;
    // 颜色原样下发，透明度由原生 applyOpacityHex 按原 alpha 相乘（避免 Dart/Kotlin 双算）。
    try {
      await _ensureNative();
      await _ch.invokeMethod('setSubtitleStyle', {
        'scale': _subtitleFontScale,
        'pos': _subtitlePos,
        'secondaryPos': _subtitleSecondaryPos,
        'forceStyle': forceStyle,
        'color': _subtitleColor,
        'borderColor': _subtitleBorderColor,
        'borderSize': forceStyle || useSystemStyle ? _subtitleBorderSize : 0,
        'bgColor': _subtitleBgColor,
        'edgeType': forceStyle || useSystemStyle ? _subtitleEdgeType : 'none',
        'useSystemStyle': _subtitleUseSystemStyle,
        'textOpacity': _subtitleTextOpacity,
        'bgOpacity': _subtitleBgOpacity,
        'edgeOpacity': _subtitleEdgeOpacity,
        'shadowStrength': forceStyle || useSystemStyle ? _subtitleShadowStrength : 0,
        'font': forceStyle || useSystemStyle ? _subtitleFont : 'default',
        'fontPath': forceStyle || useSystemStyle ? _subtitleFontPath : '',
      });
    } catch (_) {}
  }

  @override
  Future<void> setSubtitleOffsetMs(int offsetMs) async {
    _subtitleOffsetMs = offsetMs.clamp(-300000, 300000);
    try {
      await _ensureNative();
      await _ch.invokeMethod('setSubtitleOffsetMs', {'ms': _subtitleOffsetMs});
    } catch (_) {}
  }

  /// 选择副字幕轨（off/auto/default/gN:tM）。
  @override
  Future<void> setSecondarySubtitleTrack(String id) async {
    try {
      await _ensureNative();
      await _ch.invokeMethod('selectSecondarySubtitleTrack', {'id': id});
      final key = id.trim().toLowerCase();
      if (key.isEmpty || key == 'no' || key == 'off') {
        _secondarySubtitle = 'off';
        _currentSecondarySubtitleId = null;
      } else if (key == 'auto' || key == 'on') {
        _secondarySubtitle = 'auto';
        _currentSecondarySubtitleId = null;
      } else if (key == 'default' || key == 'player') {
        _secondarySubtitle = 'default';
        _currentSecondarySubtitleId = null;
      } else {
        _secondarySubtitle = 'manual';
        _currentSecondarySubtitleId = id;
      }
    } catch (_) {}
  }

  /// 预热下一集媒体到磁盘缓存（需已开磁盘缓存）。
  Future<void> warmCacheUrl(String url, {Map<String, String>? headers, int? maxBytes}) async {
    final u = url.trim();
    if (u.isEmpty || !_diskCache) return;
    try {
      await _ensureNative();
      await _ch.invokeMethod('warmCacheUrl', {
        'url': u,
        'headers': headers ?? const <String, String>{},
        if (maxBytes != null) 'maxBytes': maxBytes,
      });
    } catch (_) {}
  }

  Future<void> cancelWarmCache() async {
    try {
      await _ch.invokeMethod('cancelWarmCache');
    } catch (_) {}
  }

  /// 外挂字幕列表（open 时写入 MediaItem）。
  void setExternalSubs(List<Map<String, dynamic>> subs) {
    _subs = List<Map<String, dynamic>>.from(subs);
  }

  @override
  Future<void> addSubtitleFile(String path, {String? title}) async {
    // Exo：下次 open 时带上；当前会话追加需重建 MediaItem，先写入列表。
    final next = List<Map<String, dynamic>>.from(_subs)
      ..add({'url': path, if (title != null && title.isNotEmpty) 'name': title});
    _subs = next;
    if (_url.isNotEmpty) {
      try {
        await open(_url, headers: _headers, drm: _drm, live: _live);
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    // 正常路径已在 [release] 里 await 拆机；此处仅兜底（同样带超时）。
    if (_nativeReady) {
      _nativeReady = false;
      unawaited(
        kotvTeardownPlayback(
          stop: () async {
            try {
              await _ch.invokeMethod('stop');
            } catch (_) {}
          },
          dispose: () async {
            try {
              await _ch.invokeMethod('dispose');
            } catch (_) {}
          },
          drain: const Duration(milliseconds: 400),
          disposeTimeout: const Duration(milliseconds: 600),
        ),
      );
    }
    unawaited(_sub?.cancel() ?? Future<void>.value());
    _sub = null;
    _useFlutterTexture = false;
    _textureId = null;
    _posCtrl.close();
    _bufCtrl.close();
    _endedCtrl.close();
    super.dispose();
  }
}
