import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'buffer_budget.dart';
import 'kotv_playback.dart';
import 'kotv_platform.dart';
import 'mpv_opts.dart';
import 'mpv_surface.dart';
import 'mpv_underlay.dart';
import 'play_format.dart';
import 'play_headers.dart';
import 'player_normalize.dart';
import 'position_coalesce.dart';
import 'silent_video_guard.dart';

/// 原生 libmpv（MethodChannel `kotv_mpv`）。
/// Android：PlatformView；macOS：underlay ASBDL；Win/Linux：原生 runner。
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
  bool _previewVideoOriginal = false;
  bool _previewAudioOriginal = false;
  StreamSubscription? _sub;
  bool _nativeReady = false;
  bool _playing = false;
  bool _completed = false;
  bool _repeatOne = false;
  bool _buffering = false;
  bool _ready = false;
  /// 换源递增；旧 [kotvGuardSilentVideo] 会话见 serial 变化即退出。
  int _openSerial = 0;
  double _volume = 80;
  double _rate = 1;
  int _w = 0;
  int _h = 0;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffered = Duration.zero;
  int _speedBps = 0;
  bool _live = false;
  /// create 时写入的标定 live（与 [_live] 同步）；供 [_ensureNative] 决定是否重建。
  /// 勿与引擎 media-live 混用，否则 Surface 再挂会按点播 recreate 清掉引擎 live 态。
  bool _createdAsLive = false;
  /// 引擎 media-live（守卫用）；不挡 queueNext，也不参与 create 比较。
  bool _engineLive = false;
  String _url = '';
  Map<String, String> _headers = const {};
  String? _lastError;
  String _renderMode = 'surface';
  /// 点播挂 Surface / 停播卸下；未点播不建，避免详情滑动重影。
  bool _surfaceLayerEnabled = false;
  /// 后台仅音频：暂时抑制画面层，不改 URL。
  bool _videoOutputSuppressed = false;
  /// 适应/拉伸/Zoom/16:9/4:3（原生 setAspect）。
  String _videoScale = 'default';
  /// 开播额外属性（dvd-device / bluray-device 等）。
  Map<String, String> _extraOpenProps = const {};

  final _posCtrl = StreamController<Duration>.broadcast();
  final _bufCtrl = StreamController<Duration>.broadcast();
  final _endedCtrl = StreamController<bool>.broadcast();
  final _queuedStartCtrl = StreamController<String>.broadcast();
  /// 已排进播放列表的下一集；播到它时由 transition 事件切成当前集。
  ({String id, String url, Map<String, String> headers, String? format, List<Map<String, dynamic>> subs})? _queued;

  /// 仅随错误/就绪变化递增；供详情页 ValueListenableBuilder 重建画面（勿绑 position）。
  final ValueNotifier<int> surfaceRev = ValueNotifier(0);

  void _bumpSurface() {
    surfaceRev.value++;
  }

  bool get isReady => _ready;

  KotvMpvOpts get opts => _opts;

  @override
  void setExtraOpenProps(Map<String, String> props) {
    _extraOpenProps = Map<String, String>.from(props);
  }

  @override
  String? get lastError => _lastError;

  @override
  String get engineLabel => '内置 MPV';

  /// Surface/Texture 切换仅 Android；其它原生平台固定 underlay / HWND / 平面。
  @override
  bool get supportsRenderMode => kotvIsAndroid();

  /// 换集/开播前盖黑，避免 underlay 透明洞漏底。
  bool _underlayCover = true;

  @override
  bool get supportsStableVolume => true;

  Future<Map<Object?, Object?>?> _videoInfo() async {
    try {
      return await _ch.invokeMethod<Map<Object?, Object?>>('videoInfo');
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String?> activeDecoderLabel() async {
    final info = await _videoInfo();
    // 优先实际解码；无则回落请求的 hwdec。
    final cur = '${info?['hwdec-current'] ?? ''}'.trim();
    final req = '${info?['hwdec'] ?? ''}'.trim();
    return kotvMpvHwdecLabel(cur.isNotEmpty ? cur : req);
  }

  @override
  Future<String?> videoColorLabel() async => kotvVideoColorLabel(await _videoInfo());

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
    // 补缓存时常 buffering；已在播（含纯音频）不当作起播缓冲，避免误切。
    if (_w > 0 && _h > 0) return false;
    if (_position > const Duration(milliseconds: 300)) return false;
    if (_ready && _playing) return false;
    if (_playing && (_isAudioOnlyUnlocked || _position > const Duration(seconds: 1))) {
      return false;
    }
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
  String? _currentSubtitleId;
  String? _currentSecondarySubtitleId;

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
    if (!_ready) return;
    try {
      final rawA = await _ch.invokeMethod<String>('getAudioTracks');
      final rawV = await _ch.invokeMethod<String>('getVideoTracks');
      final rawS = await _ch.invokeMethod<String>('getSubtitleTracks');
      if (rawA != null && rawA.isNotEmpty) {
        final list = jsonDecode(rawA) as List<dynamic>;
        _audioTracks = list.map(_mapMpvTrack).toList();
      }
      if (rawV != null && rawV.isNotEmpty) {
        final list = jsonDecode(rawV) as List<dynamic>;
        _videoTracks = list.map(_mapMpvTrack).toList();
      }
      if (rawS != null && rawS.isNotEmpty) {
        final list = jsonDecode(rawS) as List<dynamic>;
        _subtitleTracks = list.map(_mapMpvTrack).toList();
      }
      notifyListeners();
    } catch (_) {}
  }

  bool get _hasRealVideoTrack =>
      _videoTracks.any((t) => kotvIsRealVideoTrack(id: t.id, codec: t.codec));

  bool get _hasRealAudioTrack => _audioTracks.isNotEmpty;

  /// 文件已 demux（对应插件 ready / 轨表）：未 loaded 前不当成「已播黑屏」。
  bool get _loaded =>
      _ready ||
      _hasRealVideoTrack ||
      _hasRealAudioTrack ||
      _duration > Duration.zero ||
      _position > Duration.zero ||
      (_w > 0 && _h > 0);

  bool get _isAudioOnlyUnlocked {
    if (_lastError != null || !_ready) return false;
    if (_w > 0 && _h > 0) return false;
    if (_hasRealVideoTrack) return false;
    return _hasRealAudioTrack;
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
    return KotvTrack(
      id: id.isEmpty ? 'auto' : id,
      label: label,
      language: lang,
      codec: codec,
    );
  }

  /// Android：PlatformView；桌面原生：underlay/HWND 洞（未就绪时黑遮）。
  Widget buildView({BoxFit fit = BoxFit.contain}) {
    if (kotvIsAndroid()) {
      return Stack(
        key: const ValueKey('kotv_mpv_surface'),
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
    if (!kotvUsesNativeMpv()) {
      return const ColoredBox(color: Colors.black);
    }
    // macOS/Win/Linux：洞显隐不绑 Android Surface 挂载态。
    final holeReady = _ready && !_videoOutputSuppressed;
    return Stack(
      key: const ValueKey('kotv_mpv_underlay'),
      fit: StackFit.expand,
      children: [
        KotvMpvUnderlayHole(
          ready: holeReady,
          coverUntilReady: _underlayCover || !_ready,
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

  @override
  Future<void> setVideoScale(String mode) async {
    final m = mode.trim().isEmpty ? 'default' : mode.trim();
    _videoScale = m;
    // 未就绪只记偏好：此处 _ensureNative 会按当前 _renderMode create，易在 setRenderMode 前锁成 Surface。
    // open 结束会再 setAspect；已就绪则热更新。
    if (!_nativeReady) return;
    try {
      await _ch.invokeMethod('setAspect', {'mode': m});
    } catch (_) {}
  }

  Future<void> _ensureNative({bool live = false}) async {
    // 标定 live 切换必须允许重建；引擎 live 不参与比较。
    if (_nativeReady && _createdAsLive == live) return;
    try {
      await _ch.invokeMethod<dynamic>('create', {
        ..._sessionDecodeArgs(),
        'gpuNext': _opts.gpuNext,
        'vulkan': _opts.vulkan,
        'conf': _opts.conf,
        'tlsVerify': _opts.tlsVerify,
        'audioPassThrough': _opts.audioPassThrough,
        'diskCache': _opts.diskCache && !live,
        'dolbyVisionPolicy': _opts.dolbyVisionPolicy,
        'bufferBytes': KotvBufferBudget.bytes(),
        'render': _renderMode,
        // 直播须在 create 时写入，磁盘缓存和 cache-pause 按这次会话来。
        'live': live,
        'repeatOne': _repeatOne,
      });
      await _sub?.cancel();
      _sub = _ev.receiveBroadcastStream().listen(_onEvent, onError: (e) {
        _lastError = '$e';
        notifyListeners();
      });
      _createdAsLive = live;
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
    // 卸文件后、下次 open 写入地址前，丢掉上一集的进度和结束事件。
    if (_url.isEmpty) return;
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
        final prev = KotvPositionSample(
          position: _position,
          duration: _duration,
          buffered: _buffered,
          playing: _playing,
          buffering: _buffering,
          speedBps: _speedBps,
        );
        // 进度走 positionStream；仅播停/缓冲态 notify（控件已不靠 Listenable 刷进度）。
        final next = KotvPositionSample.fromEvent(m, prev);
        final stateChanged = next.shouldNotifyState(prev);
        _position = next.position;
        _duration = next.duration;
        _buffered = next.buffered;
        _playing = next.playing;
        _buffering = next.buffering;
        _speedBps = next.speedBps;
        if (!_posCtrl.isClosed) _posCtrl.add(_position);
        if (!_bufCtrl.isClosed) _bufCtrl.add(_buffered);
        if (stateChanged) notifyListeners();
        break;
      case 'ready':
        final nw = (m['width'] as num?)?.toInt() ?? _w;
        final nh = (m['height'] as num?)?.toInt() ?? _h;
        if (nw > 0) _w = nw;
        if (nh > 0) _h = nh;
        _ready = true;
        _underlayCover = false;
        _lastError = null;
        if (_w > 0 && _h > 0) _buffering = false;
        unawaited(_refreshTracks());
        // 出尺寸只 notify；勿 _bumpSurface，否则易卸掉已挂的 PlatformView。
        notifyListeners();
        break;
      case 'size':
        final nw = (m['width'] as num?)?.toInt() ?? _w;
        final nh = (m['height'] as num?)?.toInt() ?? _h;
        if (nw > 0) _w = nw;
        if (nh > 0) _h = nh;
        if (_w > 0 && _h > 0) _buffering = false;
        notifyListeners();
        break;
      case 'transition':
        _enterQueued('${m['id'] ?? ''}');
        break;
      case 'completed':
        if (_completed) break;
        _completed = true;
        _playing = false;
        if (!_endedCtrl.isClosed) _endedCtrl.add(true);
        notifyListeners();
        break;
      case 'live':
        if (!kotvAcceptEngineLive(already: _engineLive, reported: m['live'] == true)) {
          break;
        }
        _engineLive = true;
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
    String? format,
    Duration startAt = Duration.zero,
    bool waitReady = true,
  }) async {
    _url = url;
    _live = live;
    _createdAsLive = live;
    _engineLive = false;
    _queued = null;
    _headers = kotvNormalizePlayHeaders(headers, url: url);
    _completed = false;
    _ready = false;
    _underlayCover = true;
    _buffering = true;
    _playing = false;
    _w = 0;
    _h = 0;
    _position = Duration.zero;
    _duration = Duration.zero;
    notifyListeners();

    // 碟片/ISO 等额外项经 open.props → applyRuntimeOpts。DRM（含 ClearKey）请用 Exo。
    if (drm != null && drm.isNotEmpty) {
      _lastError = 'MPV 不支持该 DRM，请用内置 ExoPlayer';
      _buffering = false;
      notifyListeners();
      throw StateError(_lastError!);
    }

    await _ensureNative(live: live);
    if (!_nativeReady) {
      _buffering = false;
      notifyListeners();
      throw StateError(_lastError ?? '原生 MPV 未就绪');
    }
    // 点播/直播均先挂 Surface（页面已 setState 播控进树并 endOfFrame），再 loadfile。
    // 后台仅音频抑制时不挂。
    await _syncSurfaceLayer();
    try {
      await KotvBufferBudget.warm(force: true);
      // 开播 mime：无扩展名的 /proxy/play 须靠 mime 触发 lavf HLS demuxer。
      final mime = kotvPlayMime(url, format);
      // 缺省也带 force-iso=no，避免会话复用后粘滞。
      final openProps = <String, String>{'force-iso': 'no', ..._extraOpenProps};
      _extraOpenProps = const {};
      await _ch.invokeMethod('open', {
        'url': url,
        'headers': _headers,
        if (mime != null) 'mime': mime,
        'live': live,
        ..._sessionDecodeArgs(),
        'gpuNext': _opts.gpuNext,
        'vulkan': _opts.vulkan,
        'conf': _opts.conf,
        'props': openProps,
        'tlsVerify': _opts.tlsVerify,
        'audioPassThrough': _opts.audioPassThrough,
        'diskCache': _opts.diskCache && !live,
        'bufferBytes': KotvBufferBudget.bytes(),
        'dolbyVisionPolicy': _opts.dolbyVisionPolicy,
        'preferredTextLangs': _opts.preferredTextLangs,
        'audioOffsetMs': _opts.audioOffsetMs,
        'render': _renderMode,
        if (startAt > Duration.zero) 'startAtMs': startAt.inMilliseconds,
        ..._opts.equalizerChannelArgs(),
      });
      // open 会 recreate 属性；再刷一次比例。
      await _ch.invokeMethod('setAspect', {'mode': _videoScale});
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

    _openSerial++;
    if (waitReady) {
      await awaitReadyAfterOpen();
    } else {
      notifyListeners();
    }
  }

  @override
  Future<void> awaitReadyAfterOpen() async {
    final session = _openSerial;
    bool sameSession() => _openSerial == session && _url.isNotEmpty;
    await kotvGuardSilentVideo(
      hasVideoSize: () => _w > 0 && _h > 0,
      // 未 loaded 只当缓冲等待；loaded 后才进黑屏窗口。
      isBuffering: () => sameSession() && (!_loaded || buffering),
      sessionAlive: () {
        if (_lastError != null) return false;
        return sameSession() && !completed && _loaded;
      },
      isPlaying: () => _playing,
      position: () => _position,
      duration: () => _duration,
      isLiveContent: () =>
          kotvIsLiveForGuard(markedLive: _live, engineLive: _engineLive),
      hasVideoSource: () => hasVideoSourceHint,
      isAudioOnly: () => isAudioOnlyContent,
      onFixVideoSource: tryFixVideoSource,
    );
  }

  @override
  Future<void> playOrPause() {
    return kotvTogglePlayback(playing: _playing, play: play, pause: pause);
  }

  @override
  Future<void> play() async {
    try {
      await kotvPlayRestartingFromEndIfNeeded(
        completed: _completed,
        position: _position,
        duration: _duration,
        seekZero: () async {
          await seek(Duration.zero);
          _completed = false;
        },
        play: () => _ch.invokeMethod('play'),
      );
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

  Future<void> _unloadKeepingContext() async {
    _queued = null;
    _openSerial++;
    try {
      await _ch.invokeMethod('stop');
    } catch (_) {}
    _playing = false;
    _buffering = false;
    _completed = false;
    _ready = false;
    _position = Duration.zero;
    _duration = Duration.zero;
    _buffered = Duration.zero;
    _url = '';
    _w = 0;
    _h = 0;
    if (!_posCtrl.isClosed) _posCtrl.add(Duration.zero);
    if (!_bufCtrl.isClosed) _bufCtrl.add(Duration.zero);
  }

  @override
  Future<void> stop() async {
    await _unloadKeepingContext();
    await _setSurfaceLayerEnabled(false);
    notifyListeners();
  }

  @override
  Future<void> stopForEpisodeSwitch() async {
    // 只卸文件（消音由 [kotvStopPlayersForEpisodeSwitch]）。不拆 libmpv。
    await _unloadKeepingContext();
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
    _queued = null;
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
    _rate = kotvClampPlayRate(r);
    try {
      await _ch.invokeMethod('setRate', {'rate': _rate});
    } catch (_) {}
    notifyListeners();
  }

  @override
  Future<void> setRepeatOne(bool on) async {
    _repeatOne = on;
    try {
      await _ch.invokeMethod('setRepeatOne', {'on': on});
    } catch (_) {}
    notifyListeners();
  }

  @override
  Future<void> setDecodeMode(String mode) async {
    _opts = _opts.copyWith(decodeMode: mode);
    try {
      await _ch.invokeMethod('setDecode', _sessionDecodeArgs());
    } catch (_) {}
  }

  /// decode / direct / hwdec 单点下发（桌面原生认 [KotvMpvOpts.hwdecValue]）。
  Map<String, Object?> _sessionDecodeArgs() => {
        'decode': kotvNormalizeDecodeMode(_opts.decodeMode),
        'direct': _opts.direct,
        'hwdec': _opts.hwdecValue(),
      };

  /// 原生只排点播、请求头与当前集相同的下一集（DRM 已在 [open] 拒绝，无当前 DRM 会话）。
  @override
  Future<bool> queueNext({
    required String id,
    required String url,
    Map<String, String>? headers,
    String? format,
    List<Map<String, dynamic>> subs = const [],
    Duration startAt = Duration.zero,
  }) async {
    final h = kotvNormalizePlayHeaders(headers, url: url);
    if (_url.isEmpty || _live || !mapEquals(h, _headers)) {
      return false;
    }
    try {
      final ok = await _ch.invokeMethod<bool>('queueNext', {
        'id': id,
        'url': url,
        'headers': h,
        'mime': kotvPlayMime(url, format),
        'subs': subs,
        if (startAt > Duration.zero) 'startAtMs': startAt.inMilliseconds,
      });
      _queued = ok == true ? (id: id, url: url, headers: h, format: format, subs: subs) : null;
    } catch (_) {
      _queued = null;
    }
    return _queued != null;
  }

  @override
  Future<void> clearNext() async {
    _queued = null;
    try {
      await _ch.invokeMethod('clearNext');
    } catch (_) {}
  }

  @override
  Future<bool> skipToNext() async {
    if (_queued == null) return false;
    try {
      return await _ch.invokeMethod<bool>('skipToNext') == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Stream<String> get queuedStartStream => _queuedStartCtrl.stream;

  void _enterQueued(String id) {
    final q = _queued;
    if (q == null || q.id != id) return;
    _queued = null;
    _url = q.url;
    _headers = q.headers;
    _engineLive = false;
    _openSerial++;
    _completed = false;
    _lastError = null;
    _position = Duration.zero;
    _duration = Duration.zero;
    _buffered = Duration.zero;
    // 无缝换集：勿清成 0x0（同分辨率时 size 事件可能不重发）。
    _audioTracks = const [];
    _videoTracks = const [];
    _subtitleTracks = const [];
    _currentAudioId = null;
    _currentVideoId = null;
    _currentSubtitleId = null;
    _currentSecondarySubtitleId = null;
    if (!_posCtrl.isClosed) _posCtrl.add(Duration.zero);
    if (!_queuedStartCtrl.isClosed) _queuedStartCtrl.add(id);
    notifyListeners();
    unawaited(_refreshTracks());
  }

  @override
  Future<void> setRenderMode(String mode) async {
    _renderMode = kotvNormalizePlayerRender(mode);
    try {
      if (_nativeReady) {
        await _ch.invokeMethod('setRenderMode', {'mode': _renderMode});
        await _syncSurfaceLayer();
      }
    } catch (_) {}
    _bumpSurface();
    notifyListeners();
  }

  Future<void> _syncSurfaceLayer() async {
    await _setSurfaceLayerEnabled(_url.isNotEmpty && !_videoOutputSuppressed);
  }

  @override
  Future<void> setVideoOutputEnabled(bool enabled) async {
    _videoOutputSuppressed = !enabled;
    await _syncSurfaceLayer();
  }

  Future<void> _setSurfaceLayerEnabled(bool enabled) async {
    if (_surfaceLayerEnabled == enabled) {
      if (enabled) {
        // 同态再唤一次：PlatformView 晚进树时补挂。
        try {
          await _ensureNative(live: _live);
          await _ch.invokeMethod('setSurfaceLayerEnabled', {'enabled': true});
        } catch (_) {}
      }
      return;
    }
    _surfaceLayerEnabled = enabled;
    try {
      await _ensureNative(live: _live);
      await _ch.invokeMethod('setSurfaceLayerEnabled', {'enabled': enabled});
    } catch (_) {}
  }

  Future<void> applyOpts(KotvMpvOpts opts) async {
    _opts = opts;
    try {
      await KotvBufferBudget.warm(force: true);
      await _ch.invokeMethod('setOpts', {
        ..._sessionDecodeArgs(),
        'gpuNext': opts.gpuNext,
        'vulkan': opts.vulkan,
        'conf': opts.conf,
        'tlsVerify': opts.tlsVerify,
        'audioPassThrough': opts.audioPassThrough,
        'diskCache': opts.diskCache && !_live,
        'bufferBytes': KotvBufferBudget.bytes(),
        'dolbyVisionPolicy': opts.dolbyVisionPolicy,
        'preferredTextLangs': opts.preferredTextLangs,
        'audioOffsetMs': opts.audioOffsetMs,
        ...opts.equalizerChannelArgs(),
      });
    } catch (_) {}
  }

  @override
  Future<void> setAudioOffsetMs(int offsetMs) async {
    try {
      await _ch.invokeMethod('setAudioOffsetMs', {
        'ms': offsetMs.clamp(-10000, 10000),
      });
    } catch (_) {}
  }

  @override
  Future<void> setFxPreview({bool? videoOriginal, bool? audioOriginal}) async {
    var changed = false;
    if (videoOriginal != null && videoOriginal != _previewVideoOriginal) {
      _previewVideoOriginal = videoOriginal;
      changed = true;
    }
    if (audioOriginal != null && audioOriginal != _previewAudioOriginal) {
      _previewAudioOriginal = audioOriginal;
      changed = true;
    }
    if (!changed) return;
    try {
      final videoOn = _opts.videoEq.enabled && !_previewVideoOriginal;
      final audioAf = _previewAudioOriginal || _opts.audioPassThrough
          ? ''
          : _opts.equalizerChannelArgs()['audioAf'] as String? ?? '';
      await _ch.invokeMethod('setEqualizer', {
        'eqBrightness': videoOn ? _opts.videoEq.brightness : 0,
        'eqContrast': videoOn ? _opts.videoEq.contrast : 0,
        'eqSaturation': videoOn ? _opts.videoEq.saturation : 0,
        'eqGamma': videoOn ? _opts.videoEq.gamma : 0,
        'eqHue': videoOn ? _opts.videoEq.hue : 0,
        'eqSharpness': videoOn ? _opts.videoEq.sharpness : 0,
        'audioAf': audioAf,
        'videoVf': videoOn ? _opts.videoEq.mpvVf() : '',
        'subtitleFontScale': _opts.subtitleFontScale.clamp(0.5, 2.0),
      });
    } catch (_) {}
  }

  @override
  Future<void> setStableVolume(bool on) async {
    _opts = _opts.copyWith(stableVolume: on);
    try {
      // 走 setEqualizer：和其它音效合成同一条 af，原生端直通时不写。
      await _ch.invokeMethod('setEqualizer', _opts.equalizerChannelArgs());
    } catch (_) {}
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
      final key = id.trim().toLowerCase();
      if (key.isEmpty || key == 'no' || key == 'off') {
        _currentSubtitleId = null;
      } else if (key == 'auto') {
        _currentSubtitleId = 'auto';
      } else {
        _currentSubtitleId = id;
      }
      notifyListeners();
    } catch (_) {}
  }

  @override
  Future<void> setSecondarySubtitleTrack(String id) async {
    try {
      await _ch.invokeMethod('setSecondarySubtitleTrack', {'id': id});
      final key = id.trim().toLowerCase();
      if (key.isEmpty || key == 'no' || key == 'off' || key == 'none') {
        _currentSecondarySubtitleId = null;
      } else if (key == 'auto') {
        _currentSecondarySubtitleId = null;
      } else {
        _currentSecondarySubtitleId = id.trim();
      }
      notifyListeners();
    } catch (_) {}
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
    try {
      await _ch.invokeMethod('setSubtitleStyle', {
        if (scale != null) 'scale': scale,
        if (pos != null) 'pos': pos,
        if (secondaryPos != null) 'secondaryPos': secondaryPos,
        'forceStyle': forceStyle,
        if (color != null) 'color': color,
        if (borderColor != null) 'borderColor': borderColor,
        if (borderSize != null) 'borderSize': borderSize,
        if (bgColor != null) 'bgColor': bgColor,
        if (edgeType != null) 'edgeType': edgeType,
        'useSystemStyle': useSystemStyle,
        if (textOpacity != null) 'textOpacity': textOpacity,
        if (bgOpacity != null) 'bgOpacity': bgOpacity,
        if (edgeOpacity != null) 'edgeOpacity': edgeOpacity,
        if (shadowStrength != null) 'shadowStrength': shadowStrength,
        if (font != null) 'font': font,
        if (fontPath != null) 'fontPath': fontPath,
      });
    } catch (_) {}
  }

  @override
  Future<void> setSubtitleOffsetMs(int offsetMs) async {
    try {
      await _ch.invokeMethod('setSubtitleOffsetMs', {
        'ms': offsetMs.clamp(-300000, 300000),
      });
    } catch (_) {}
  }

  @override
  Future<void> addSubtitleFile(String path, {String? title}) async {
    try {
      await _ch.invokeMethod('addSubtitle', {
        'path': path,
        if (title != null && title.isNotEmpty) 'title': title,
        'select': true,
      });
      await _refreshTracks();
    } catch (_) {}
  }

  @override
  /// 桌面原生桥尚未接碟片导航（Android 原生另有实现）。
  bool get supportsDiscNav => kotvIsAndroid();

  @override
  Future<List<KotvTrack>> discTitles() async {
    try {
      // MediaEdition.index 为 0-based。
      final n = await _ch.invokeMethod<int>('discTitleCount') ?? 0;
      if (n <= 0) return const [];
      return [for (var i = 0; i < n; i++) KotvTrack(id: '$i', label: '标题 ${i + 1}')];
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<List<KotvTrack>> discChapters() async {
    try {
      final n = await _ch.invokeMethod<int>('discChapterCount') ?? 0;
      if (n <= 0) return const [];
      return [for (var i = 0; i < n; i++) KotvTrack(id: '$i', label: '章节 ${i + 1}')];
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> setDiscTitle(int index) async {
    try {
      await _ch.invokeMethod('setDiscTitle', {'index': index});
    } catch (_) {}
  }

  @override
  Future<void> setDiscChapter(int index) async {
    try {
      await _ch.invokeMethod('setDiscChapter', {'index': index});
    } catch (_) {}
  }

  @override
  Future<void> openDiscMenu() async {
    // 原生 MPVLib：discnav menu 由插件 openDiscMenu 映射。
    try {
      await _ch.invokeMethod('openDiscMenu');
    } catch (_) {}
  }

  @override
  Future<void> tryFixVideoSource() async {
    if (_url.isEmpty) return;
    try {
      await _refreshTracks();
      if (_videoTracks.isEmpty) {
        if (_audioTracks.isNotEmpty) return;
        await play();
        return;
      }
      for (final t in _videoTracks) {
        await setVideoTrack(t.id);
        await Future<void>.delayed(const Duration(milliseconds: 350));
        if (_w > 0 && _h > 0) return;
      }
      await _ch.invokeMethod('retryVideo');
    } catch (_) {
      try {
        await play();
      } catch (_) {}
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
    unawaited(_queuedStartCtrl.close());
    super.dispose();
  }
}
