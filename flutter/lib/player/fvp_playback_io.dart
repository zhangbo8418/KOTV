import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:fvp/fvp.dart' show FVPControllerExtensions;
import 'package:video_player/video_player.dart';

import 'buffer_budget.dart';
import 'fvp_decoders.dart';
import 'drm_opts.dart';
import 'fvp_register.dart';
import 'kotv_playback.dart';
import 'kotv_platform.dart';
import 'play_headers.dart';
import 'playback_settings.dart';
import 'silent_video_guard.dart';
import 'video_eq.dart';
import 'video_scale_fit.dart';

/// 页内 FVP（libmdk）：经 [video_player] + fvp 插件。
///
/// 须在首次使用 FVP 前调用 [kotvEnsureFvpRegistered]（见 [kotvRegisterFvp]）。
/// 解码器与 ClearKey 由 registerWith 在 prepare 前写入；initialize 之前的
/// setVideoDecoders / setProperty 没有 player，插件会直接丢掉。
///
/// 起播顺序：先挂 [VideoPlayer]（建立 Texture/Surface），再 `initialize`/`play`。
class FvpPlayback extends KotvPlayback {
  VideoPlayerController? _c;
  final _posCtrl = StreamController<Duration>.broadcast();
  final _bufCtrl = StreamController<Duration>.broadcast();
  final _doneCtrl = StreamController<bool>.broadcast();
  VoidCallback? _listener;
  bool _completed = false;
  bool _opening = false;
  bool _live = false;
  String? _lastError;
  double _volume = 100;
  double _rate = 1;
  String _decodeMode = 'auto';
  /// 安卓：`playerRender` surface|texture（与 Exo 同源；桌面固定 Texture）。
  String _renderMode = 'surface';
  String? _lastUrl;
  Map<String, String>? _lastHeaders;
  Map<String, dynamic>? _lastDrm;
  bool _lastLive = false;
  String? _lastFormat;
  String _videoScale = 'default';
  /// 仅尺寸/比例/错误变化时递增，供 buildView 重建（勿绑 position/buffering）。
  final ValueNotifier<int> _viewGen = ValueNotifier<int>(0);

  /// 安卓 Surface：platformView + image=0。Texture：textureView。
  bool get _androidSurface => kotvIsAndroid() && _renderMode == 'surface';

  VideoViewType get _viewType {
    if (!kotvIsAndroid()) return VideoViewType.textureView;
    return _renderMode == 'surface'
        ? VideoViewType.platformView
        : VideoViewType.textureView;
  }

  List<KotvTrack> _audioTracks = const [];
  List<KotvTrack> _videoTracks = const [];
  List<KotvTrack> _subtitleTracks = const [];
  String? _currentAudioId;
  String? _currentVideoId;
  String? _currentSubtitleId;
  String? _currentSecondarySubtitleId;
  bool _subtitleManualOff = false;
  bool _subtitleManualAuto = false;
  String _secondarySubtitleMode = 'default';
  double _subtitleFontScale = 1.0;
  String _preferredTextLangs = '';
  KotvVideoEq _videoEq = KotvVideoEq.off;
  KotvAudioEqPreset _audioEq = KotvAudioEqPreset.off;
  String _audioEqBands = '';
  int _audioDialogue = 0;
  int _audioBalance = 0;
  int _audioStability = 0;
  int _audioBoost = 0;
  int _audioPreamp = 0;
  int _audioCenterGain = 0;
  String _audioChannelMode = 'auto';
  int _audioOffsetMs = 0;
  bool _previewVideoOriginal = false;
  bool _previewAudioOriginal = false;
  bool _liveBufferSet = false;
  bool _vodBufferSet = false;

  VideoPlayerController? get controller => _c;

  @override
  String? get lastError => _lastError;

  @override
  bool get playing => _opening ? false : (_c?.value.isPlaying ?? false);

  @override
  bool get completed => _completed;

  @override
  Duration get position => _c?.value.position ?? Duration.zero;

  @override
  Duration get duration => _c?.value.duration ?? Duration.zero;

  @override
  Duration get buffered {
    final ranges = _c?.value.buffered;
    if (ranges == null || ranges.isEmpty) return Duration.zero;
    var end = Duration.zero;
    for (final r in ranges) {
      if (r.end > end) end = r.end;
    }
    return end;
  }

  /// 起播整段（含 initialize）视为缓冲，避免 `stop()` 清掉标记后浮层消失。
  @override
  bool get buffering => _opening || (_c?.value.isBuffering ?? false);

  @override
  double get volume => _volume;

  @override
  double get rate => _rate;

  @override
  int get width => _c?.value.size.width.toInt() ?? 0;

  @override
  int get height => _c?.value.size.height.toInt() ?? 0;

  @override
  String get engineLabel => '内置 FVP';

  @override
  Stream<Duration> get positionStream => _posCtrl.stream;

  @override
  Stream<Duration> get bufferedStream => _bufCtrl.stream;

  @override
  Stream<bool> get completedStream => _doneCtrl.stream;

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

  Widget buildView({BoxFit fit = BoxFit.contain}) {
    // 只跟 _viewGen（尺寸/比例），不跟 position/buffering 的 notifyListeners。
    return ValueListenableBuilder<int>(
      valueListenable: _viewGen,
      builder: (context, _, __) => _buildViewBody(fit: fit),
    );
  }

  void _bumpView() {
    _viewGen.value++;
  }

  Widget _buildViewBody({required BoxFit fit}) {
    final c = _c;
    if (c == null) {
      return const ColoredBox(color: Colors.black);
    }
    final err = c.value.errorDescription ?? _lastError;
    if (err != null && err.isNotEmpty && !c.value.isInitialized) {
      return ColoredBox(
        color: Colors.black,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              err,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
        ),
      );
    }
    // VideoPlayer 须固定在同一子树位置——
    // Texture：若 size 0↔正 时整段换父级，ImageReader 会 1x1↔实尺寸反复 disconnect。
    // Surface/platformView：吃不到 FittedBox 变换，须按视频比例给真实布局尺寸。
    final scale = _videoScale.trim().isEmpty ? 'default' : _videoScale.trim();
    final surfaceLayout = _androidSurface;
    return LayoutBuilder(
      builder: (context, constraints) {
        final max = constraints.biggest;
        if (!max.width.isFinite || !max.height.isFinite || max.width <= 0 || max.height <= 0) {
          return ColoredBox(color: Colors.black, child: VideoPlayer(c));
        }
        final sz = c.value.size;
        final hasSize = c.value.isInitialized && sz.width > 0 && sz.height > 0;
        final videoSize = hasSize ? sz : const Size(16, 9);
        final box = hasSize ? kotvBoxForVideoScale(max, videoSize, scale) : max;
        final effective = kotvFitFromVideoScale(scale, fit);
        final w = box.width.isFinite && box.width > 0 ? box.width : max.width;
        final h = box.height.isFinite && box.height > 0 ? box.height : max.height;
        final Widget child;
        if (surfaceLayout) {
          if (effective == BoxFit.fill && kotvForcedAspectRatio(scale) == null) {
            return SizedBox(width: max.width, height: max.height, child: VideoPlayer(c));
          }
          child = SizedBox(width: w, height: h, child: VideoPlayer(c));
        } else {
          child = SizedBox(
            width: w,
            height: h,
            child: FittedBox(
              fit: effective == BoxFit.fill ? BoxFit.fill : BoxFit.contain,
              child: SizedBox(
                width: videoSize.width,
                height: videoSize.height,
                child: VideoPlayer(c),
              ),
            ),
          );
        }
        if (effective == BoxFit.cover) {
          return ClipRect(child: Center(child: child));
        }
        return ColoredBox(color: Colors.black, child: Center(child: child));
      },
    );
  }

  /// 摘掉 listener 后走统一拆机：pause → 压空队列 → dispose。
  ///
  /// 不设 disposeTimeout：超时把 dispose 丢后台时，上一集的 mdk 包缓存会留下来；
  /// 连播多集后进程内存会一直涨（c8394d8 / kotvTeardownPlayback 注释同因）。
  /// 删播放器前先把 buffer 压到几乎为空，避免大队列拖慢 mdkPlayerAPI_delete。
  Future<void> _disposeController() async {
    final c = _c;
    final l = _listener;
    _c = null;
    _listener = null;
    if (c == null) return;
    _bumpView();
    if (l != null) {
      try {
        c.removeListener(l);
      } catch (_) {}
    }
    await kotvTeardownPlayback(
      stop: () async {
        try {
          await c.pause();
        } catch (_) {}
        try {
          c.setBufferRange(min: 0, max: 1, drop: true);
        } catch (_) {}
      },
      dispose: () async {
        await c.dispose();
      },
      drain: const Duration(milliseconds: 50),
    );
  }

  @override
  Future<void> open(
    String url, {
    Map<String, String>? headers,
    Map<String, dynamic>? drm,
    bool live = false,
    String? format,
    Duration startAt = Duration.zero,
  }) async {
    final clearKeyHex = kotvIsLocalClearKey(drm) ? kotvClearKeyHex(drm) : null;
    if (drm != null && '${drm['type'] ?? ''}'.trim().isNotEmpty && clearKeyHex == null) {
      throw UnsupportedError('DRM 内容请使用内置 ExoPlayer');
    }
    _lastUrl = url;
    _lastHeaders = headers == null ? null : Map<String, String>.from(headers);
    _lastDrm = drm == null ? null : Map<String, dynamic>.from(drm);
    _lastLive = live;
    _lastFormat = format;
    kotvEnsureFvpRegistered(
      decodeMode: _decodeMode,
      clearKeyHex: clearKeyHex,
      syncClearKey: true,
      androidSurface: _androidSurface,
    );
    _opening = true;
    _live = live;
    _liveBufferSet = false;
    _vodBufferSet = false;
    _lastError = null;
    _completed = false;
    _audioTracks = const [];
    _videoTracks = const [];
    _subtitleTracks = const [];
    _currentAudioId = null;
    _currentVideoId = null;
    _currentSubtitleId = null;
    _currentSecondarySubtitleId = null;
    _subtitleManualOff = false;
    _subtitleManualAuto = false;
    notifyListeners();
    try {
      // 换源须 dispose 再建；勿先走 stop()（会清 _opening，缓冲浮层立刻消失）。
      await _disposeController();
      notifyListeners();
      final h = kotvNormalizePlayHeaders(headers, url: url);
      // 点播续播/片头：X-KOTV-Prepare-Ms → fvp patch prepare(ms)（对齐 Mac MPV Media.start /
      // mdk prepare(startPosition)）。勿 prepare(0) 后再 seekTo——安卓 AMediaCodec
      // STARTED→FLUSHING→Avg≈1000ms；Mac FVP 走 VT，无此链。
      final openHeaders = Map<String, String>.from(h);
      if (startAt > Duration.zero) {
        openHeaders['X-KOTV-Prepare-Ms'] = '${startAt.inMilliseconds}';
      }
      // 302 交给 mdk 默认 IO 跟跳（未强制 io.avio）。
      final c = VideoPlayerController.networkUrl(
        Uri.parse(url),
        httpHeaders: openHeaders,
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
        // 安卓跟 playerRender：Surface→platformView，Texture→textureView（Win7 adapt 删本行）。
        viewType: _viewType,
      );
      _c = c;
      _bumpView();
      var lastInit = false;
      var lastPlaying = false;
      var lastBuffering = false;
      var lastW = 0.0;
      var lastH = 0.0;
      var lastErr = '';
      var lastOpening = true;
      _listener = () {
        if (_c != c) return;
        final v = c.value;
        if (v.hasError) {
          _lastError = v.errorDescription ?? 'FVP 播放错误';
        }
        if (_opening &&
            (v.isPlaying ||
                v.isBuffering ||
                v.position > Duration.zero ||
                (v.isInitialized && v.size.width > 0) ||
                v.isCompleted)) {
          _opening = false;
        }
        _posCtrl.add(v.position);
        if (v.buffered.isNotEmpty) {
          var end = Duration.zero;
          for (final r in v.buffered) {
            if (r.end > end) end = r.end;
          }
          _bufCtrl.add(end);
        }
        if (v.isCompleted && !_completed) {
          _completed = true;
          _doneCtrl.add(true);
        }
        if (v.isInitialized && !_opening) {
          _refreshTracksQuiet();
        }
        if (v.isInitialized && !_vodBufferSet &&
            (lastInit != v.isInitialized || lastBuffering != v.isBuffering)) {
          _applyBufferRange(c);
        }
        // 勿因 position 高频 notify：页面 ListenableBuilder 会重建 Texture。
        // 尺寸短暂掉到 0 不 _bumpView：避免 Texture ImageReader 因 size 抖动拆建。
        final err = v.errorDescription ?? _lastError ?? '';
        final w = v.size.width;
        final h = v.size.height;
        final sizeReady = w > 0 && h > 0;
        final lastReady = lastW > 0 && lastH > 0;
        final viewChanged = lastInit != v.isInitialized ||
            lastErr != err ||
            (sizeReady &&
                (!lastReady || (lastW - w).abs() > 1.0 || (lastH - h).abs() > 1.0));
        final uiChanged = viewChanged ||
            lastPlaying != v.isPlaying ||
            lastBuffering != v.isBuffering ||
            lastOpening != _opening ||
            v.isCompleted;
        if (!uiChanged) return;
        lastInit = v.isInitialized;
        lastPlaying = v.isPlaying;
        lastBuffering = v.isBuffering;
        if (sizeReady) {
          lastW = w;
          lastH = h;
        }
        lastErr = err;
        lastOpening = _opening;
        if (viewChanged) _bumpView();
        notifyListeners();
      };
      c.addListener(_listener!);
      // 先让父级 rebuild 挂上 VideoPlayer，再 initialize。
      notifyListeners();
      await SchedulerBinding.instance.endOfFrame;
      await Future<void>.delayed(const Duration(milliseconds: 32));
      await c.initialize();
      if (c.value.hasError) {
        _lastError = c.value.errorDescription ?? 'FVP initialize 失败';
        throw StateError(_lastError!);
      }
      // 单一路径钉死 min=0（勿省略 max：Dart 默认 max=-1 会把 max/drop 打回 mdk 默认）。
      // 点播默认 minMs=1000 → 欠载约每秒一帧（ADB MediaCodec timediff≈1000ms）。
      try {
        if (!_live) await KotvBufferBudget.warm();
      } catch (_) {}
      _applyBufferRange(c);
      await c.setVolume((_volume / 100).clamp(0, 1));
      await c.setPlaybackSpeed(_rate);
      // startAt 已在 create→prepare(ms)；此处勿再 seekTo。
      await c.play();
      _applyRuntimeOptions(c);
      _refreshTracksQuiet();
      _applySecondaryAutoIfNeeded();
      unawaited(setVideoScale(_videoScale));
      // 直播可能长时间 size=0：保持 _opening 直到首帧/出尺寸，浮层继续显示。
      if (c.value.isPlaying && c.value.size.width > 0) {
        _opening = false;
      }
      notifyListeners();
      await _guardSilentVideo(c);
      _refreshTracksQuiet();
      _applySecondaryAutoIfNeeded();
    } catch (e) {
      _lastError = '$e';
      _opening = false;
      notifyListeners();
      rethrow;
    }
  }

  /// 开播后短等出尺寸；仍无画面且会话存活则抛 [KotvSilentVideoException]。
  Future<void> _guardSilentVideo(VideoPlayerController c) async {
    await kotvGuardSilentVideo(
      hasVideoSize: () {
        if (!identical(_c, c)) return true;
        final v = c.value;
        return v.isInitialized && v.size.width > 0 && v.size.height > 0;
      },
      isBuffering: () {
        if (!identical(_c, c)) return false;
        return _opening || c.value.isBuffering;
      },
      sessionAlive: () {
        if (!identical(_c, c)) return false;
        final v = c.value;
        if (v.hasError) return false;
        return v.isPlaying || v.position > Duration.zero;
      },
      isPlaying: () {
        if (!identical(_c, c)) return false;
        return c.value.isPlaying;
      },
      position: () => c.value.position,
      duration: () => c.value.duration,
      isLiveContent: () {
        if (_live) return true;
        try {
          return identical(_c, c) && c.isLive();
        } catch (_) {
          return false;
        }
      },
      hasVideoSource: () {
        if (!identical(_c, c)) return true;
        return hasVideoSourceHint;
      },
      isAudioOnly: () => isAudioOnlyContent,
      onFixVideoSource: tryFixVideoSource,
    );
    if (identical(_c, c) && c.value.hasError) {
      throw StateError(c.value.errorDescription ?? _lastError ?? 'FVP 播放错误');
    }
    if (identical(_c, c)) {
      _opening = false;
      notifyListeners();
      final v = c.value;
      final hasSize = v.isInitialized && v.size.width > 0 && v.size.height > 0;
      if (!hasSize && !isAudioOnlyContent) {
        throw const KotvSilentVideoException();
      }
    }
  }

  @override
  bool get hasVideoSourceHint {
    final c = _c;
    if (c == null) return false;
    final v = c.value;
    if (v.hasError) return false;
    if (isAudioOnlyContent) return true;
    // Web 上 fvp 的 MediaInfo 是 dummy（无 video/audio）；用 dynamic 避免 dart2js 编译失败。
    try {
      final info = c.getMediaInfo() as dynamic;
      final videos = info?.video as List?;
      if (videos != null && videos.isNotEmpty) {
        final active = c.getActiveVideoTracks() ?? const <int>[];
        // 有视频流但未激活任何轨 → 视源异常，触发重选。
        return active.isNotEmpty;
      }
    } catch (_) {}
    return v.isInitialized || _opening;
  }

  @override
  bool get isAudioOnlyContent {
    final c = _c;
    if (c == null) return false;
    final v = c.value;
    if (!v.isInitialized || v.isBuffering || _opening) return false;
    if (v.size.width > 0 && v.size.height > 0) return false;
    // 仅在 demux 确认「无视轨 + 有音轨」时放行；禁止用「在播+无尺寸」瞎猜。
    try {
      final info = c.getMediaInfo() as dynamic;
      if (info != null) {
        final hasVideo = (info.video as List?)?.isNotEmpty == true;
        final hasAudio = (info.audio as List?)?.isNotEmpty == true;
        if (!hasVideo && hasAudio) {
          return v.isPlaying || v.position > const Duration(milliseconds: 500);
        }
      }
    } catch (_) {}
    return false;
  }

  @override
  Future<void> tryFixVideoSource() async {
    final c = _c;
    if (c == null) return;
    try {
      final info = c.getMediaInfo() as dynamic;
      final videos = List<dynamic>.from((info?.video as List?) ?? const []);
      if (videos.isNotEmpty) {
        videos.sort((a, b) {
          final aa = (a.codec.width as int) * (a.codec.height as int);
          final bb = (b.codec.width as int) * (b.codec.height as int);
          return bb.compareTo(aa);
        });
        for (final stream in videos) {
          try {
            c.setVideoTracks([stream.index as int]);
            await Future<void>.delayed(const Duration(milliseconds: 350));
            if (!identical(_c, c)) return;
            final sz = c.value.size;
            if (sz.width > 0 && sz.height > 0) return;
          } catch (_) {}
        }
      }
      final programs = info?.programs as List?;
      if (programs != null && programs.length > 1) {
        for (var i = 0; i < programs.length; i++) {
          try {
            c.setProgram(i);
            await Future<void>.delayed(const Duration(milliseconds: 350));
            if (!identical(_c, c)) return;
            final sz = c.value.size;
            if (sz.width > 0 && sz.height > 0) return;
          } catch (_) {}
        }
      }
      await c.play();
    } catch (_) {
      try {
        await c.play();
      } catch (_) {}
    }
  }

  @override
  Future<void> playOrPause() async {
    final c = _c;
    if (c == null) return;
    if (c.value.isPlaying) {
      await c.pause();
    } else {
      await c.play();
    }
    notifyListeners();
  }

  @override
  Future<void> play() async {
    await _c?.play();
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    await _c?.pause();
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    _opening = false;
    _lastError = null;
    await _disposeController();
    notifyListeners();
  }

  // 换源必须新建 VideoPlayerController，故不覆写 stopForEpisodeSwitch（默认走 stop/dispose）。

  @override
  Future<void> release() => stop();

  @override
  Future<void> seek(Duration d) async {
    final c = _c;
    if (c == null) return;
    await c.seekTo(d);
    // seek/flush 后 mdk 会把 minMs 打回默认 1000；清标志再钉死 min=0。
    _vodBufferSet = false;
    _liveBufferSet = false;
    _applyBufferRange(c);
    notifyListeners();
  }

  @override
  Future<void> setVolume(double v) async {
    _volume = v.clamp(0, 100);
    await _c?.setVolume((_volume / 100).clamp(0, 1));
    notifyListeners();
  }

  @override
  Future<void> setRate(double r) async {
    _rate = r.clamp(0.25, 4.0);
    await _c?.setPlaybackSpeed(_rate);
    notifyListeners();
  }

  @override
  Future<void> setRepeatOne(bool on) async {
    await _c?.setLooping(on);
  }

  @override
  Future<void> setDecodeMode(String mode) async {
    final next = switch (mode.trim().toLowerCase()) {
      'soft' || 'software' || 'sw' => 'soft',
      'hard' || 'hardware' || 'hw' => 'hard',
      _ => 'auto',
    };
    if (next == _decodeMode) {
      _applyDecodeMode(_c);
      return;
    }
    _decodeMode = next;
    // 下一次 prepare 走新列表；已经在播的这一路要当场换解码器。
    kotvEnsureFvpRegistered(decodeMode: next, androidSurface: _androidSurface);
    _applyDecodeMode(_c);
  }

  @override
  Future<void> setRenderMode(String mode) async {
    final next = kotvNormalizePlayerRender(mode);
    if (next == _renderMode) return;
    _renderMode = next;
    kotvEnsureFvpRegistered(decodeMode: _decodeMode, androidSurface: _androidSurface);
    final url = _lastUrl;
    if (url == null || url.isEmpty || _c == null) {
      notifyListeners();
      return;
    }
    // viewType / 解码器在 create 时定死，须重建；进度经 startAt 在首次 play 前恢复。
    final pos = position;
    final wasPlaying = playing && !buffering;
    try {
      await open(
        url,
        headers: _lastHeaders,
        drm: _lastDrm,
        live: _lastLive,
        format: _lastFormat,
        startAt: pos > Duration.zero ? pos : Duration.zero,
      );
      if (!wasPlaying) {
        try {
          await pause();
        } catch (_) {}
      }
    } catch (_) {}
    notifyListeners();
  }

  /// 仅对已经 initialize 的播放器生效。开播那次的列表在 registerWith 里。
  void _applyDecodeMode(VideoPlayerController? c) {
    if (c == null || !c.value.isInitialized) return;
    try {
      c.setVideoDecoders(
        kotvFvpVideoDecoders(_decodeMode, androidSurface: _androidSurface),
      );
    } catch (_) {}
    // 全局 shader_resource=1 仅 win8+；Win7 写了会卡住平台线程。
    if (kotvIsWindows() && !kotvIsWindows7()) {
      try {
        c.setProperty('video.decoder', 'shader_resource=1');
      } catch (_) {}
    }
  }

  void applyPlayerOptions(Map<String, dynamic> settings) {
    _subtitleFontScale = double.tryParse('${settings['subtitleFontScale'] ?? '1.0'}') ?? 1.0;
    _subtitleFontScale = _subtitleFontScale.clamp(0.5, 2.0);
    final sec = '${settings['exoSecondarySubtitle'] ?? 'default'}'.trim().toLowerCase();
    _secondarySubtitleMode = (sec == 'auto' || sec == 'on' || sec == 'manual' || sec == 'default' || sec == 'player')
        ? (sec == 'on' ? 'auto' : (sec == 'player' ? 'default' : sec))
        : 'default';
    _preferredTextLangs = kotvPreferredTextLangsFromSettings(settings);
    _videoEq = KotvVideoEq.fromSettings(settings);
    _audioEq = kotvAudioEqFromSettings(settings);
    _audioEqBands = kotvAudioEqBandsFromSettings(settings);
    _audioDialogue = kotvAudioDialogueFromSettings(settings);
    _audioBalance = kotvAudioBalanceFromSettings(settings);
    _audioStability = kotvAudioStabilityFromSettings(settings);
    _audioBoost = kotvAudioBoostFromSettings(settings);
    _audioPreamp = kotvAudioPreampFromSettings(settings);
    _audioCenterGain = kotvAudioCenterGainFromSettings(settings);
    _audioChannelMode = kotvAudioChannelModeFromSettings(settings);
    _audioOffsetMs = kotvAudioOffsetMsFromSettings(settings);
    _applyRuntimeOptions(_c);
    _applySecondaryAutoIfNeeded();
    notifyListeners();
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
    final c = _c;
    if (c == null || !c.value.isInitialized) return;
    try {
      _writeFxFilters(c);
    } catch (_) {}
  }

  void _writeFxFilters(VideoPlayerController c) {
    c.setProperty('video.avfilter', _previewVideoOriginal ? '' : _videoEq.fvpAvfilter());
    // loudness 恒 false：见 setStableVolume（dynaudnorm/loudnorm 会弄死 AO）。
    c.setProperty(
      'audio.avfilter',
      _previewAudioOriginal
          ? ''
          : kotvAudioEqFvpFilter(
              _audioEq,
              bands: _audioEqBands,
              dialogue: _audioDialogue,
              balance: _audioBalance,
              channelMode: _audioChannelMode,
              stability: _audioStability,
              boost: _audioBoost,
              preamp: _audioPreamp,
              loudness: false,
              centerGain: _audioCenterGain,
            ),
    );
  }

  void _applyRuntimeOptions(VideoPlayerController? c) {
    if (c == null || !c.value.isInitialized) return;
    try {
      c.setProperty('subtitle.scale', _subtitleFontScale.toStringAsFixed(2));
      final langs = _preferredTextLangs.isNotEmpty
          ? _preferredTextLangs
          : kotvPreferredTextLanguagesFromLocale().join(',');
      if (langs.isNotEmpty) {
        c.setProperty('subtitle.language', langs);
      }
      _writeFxFilters(c);
      c.setProperty('audio.delay', (_audioOffsetMs / 1000.0).toStringAsFixed(3));
      _syncSubtitleTracks(c);
    } catch (_) {}
  }

  String _metaLabel(Map<String, String> metadata, {String? codec, int w = 0, int h = 0}) {
    var label = (metadata['title'] ?? metadata['language'] ?? metadata['lang'] ?? '').trim();
    if (label.isEmpty) label = (metadata['handler_name'] ?? '').trim();
    if (codec != null && codec.isNotEmpty) {
      label = label.isEmpty ? codec : '$label ($codec)';
    }
    if (w > 0 && h > 0) label = '$label ${w}x$h';
    return label.isEmpty ? '?' : label;
  }

  int? _parseTrackIndex(String id) {
    final t = id.trim();
    if (t.isEmpty || kotvIsPseudoMediaTrack(t)) return null;
    if (t.contains(':')) {
      final tail = t.split(':').last;
      return int.tryParse(tail.replaceFirst(RegExp(r'^[tg]'), ''));
    }
    return int.tryParse(t.replaceFirst(RegExp(r'^[tg]'), ''));
  }

  int _mediaBitsPerSec(VideoPlayerController c) {
    final info = c.getMediaInfo() as dynamic;
    if (info == null) return 0;
    final top = info.bitRate;
    if (top is int && top > 0) return top;
    var sum = 0;
    for (final list in [info.video, info.audio]) {
      if (list is! List) continue;
      for (final stream in list) {
        final b = (stream as dynamic).codec?.bitRate;
        if (b is int && b > 0) sum += b;
      }
    }
    return sum;
  }

  /// mdk [setBufferRange]：`minMs==0` 尽快解码；`minMs>0` 时队列空了要攒到 min 才继续出包。
  /// 默认 min=1000，欠载时大约每秒才放出一帧（ADB MediaCodec timediff≈1000ms）。
  /// 点播固定 min=0；max 用内存预算÷码率。码率未知时先用 60s，码率出来再抬 max。
  /// 直播：短队列；桌面 drop 追沿，安卓不 drop（GOP≈1s 时 drop 会只剩关键帧）。
  /// （属性 `buffer` 与本 API 等价；开播路径只调 setBufferRange。）
  void _applyBufferRange(VideoPlayerController c) {
    if (!identical(_c, c)) return;
    try {
      if (_live) {
        if (_liveBufferSet) return;
        final maxMs = kotvIsDesktop() ? 8000 : 4000;
        final drop = kotvIsDesktop();
        c.setBufferRange(min: 0, max: maxMs, drop: drop);
        _liveBufferSet = true;
        _vodBufferSet = false;
        return;
      }
      if (_vodBufferSet) return;
      final bps = _mediaBitsPerSec(c);
      final maxMs = bps > 0
          ? KotvBufferBudget.fvpMaxBufferMs(
              KotvBufferBudget.bytes(),
              bitsPerSec: bps,
            )
          : 60000;
      // max 算不出来也必须先钉死 min=0，绝不能 return 留下 mdk 默认 minMs=1000。
      if (maxMs <= 0) {
        c.setBufferRange(min: 0, max: 0);
        return;
      }
      c.setBufferRange(min: 0, max: maxMs, drop: false);
      if (bps > 0) {
        _vodBufferSet = true;
        _liveBufferSet = false;
      }
    } catch (_) {}
  }

  void _refreshTracksQuiet() {
    final c = _c;
    if (c == null || !c.value.isInitialized) return;
    if (!_vodBufferSet) _applyBufferRange(c);
    try {
      final info = c.getMediaInfo() as dynamic;
      if (info == null) return;
      _audioTracks = _mapStreamTracks(info.audio, isVideo: false);
      _videoTracks = _mapStreamTracks(info.video, isVideo: true);
      _subtitleTracks = _mapStreamTracks(info.subtitle, isVideo: false);

      final actA = c.getActiveAudioTracks() ?? const <int>[];
      _currentAudioId = actA.isEmpty ? null : '${actA.first}';
      final actV = c.getActiveVideoTracks() ?? const <int>[];
      _currentVideoId = actV.isEmpty ? null : '${actV.first}';
      final actS = c.getActiveSubtitleTracks() ?? const <int>[];
      if (actS.isEmpty) {
        _currentSubtitleId = _subtitleManualOff || _subtitleManualAuto ? null : _currentSubtitleId;
        if (!_subtitleManualOff && !_subtitleManualAuto) {
          _currentSecondarySubtitleId = null;
        }
      } else {
        _currentSubtitleId = '${actS.first}';
        _currentSecondarySubtitleId = actS.length > 1 ? '${actS[1]}' : null;
      }
    } catch (_) {}
  }

  List<KotvTrack> _mapStreamTracks(dynamic streams, {required bool isVideo}) {
    if (streams is! List || streams.isEmpty) return const [];
    final out = <KotvTrack>[];
    for (final s in streams) {
      try {
        final index = s.index as int;
        final meta = Map<String, String>.from((s.metadata as Map?)?.map(
              (k, v) => MapEntry('$k', '$v'),
            ) ??
            const {});
        final codec = '${s.codec.codec ?? ''}'.trim();
        var w = 0;
        var h = 0;
        if (isVideo) {
          w = (s.codec.width as num?)?.toInt() ?? 0;
          h = (s.codec.height as num?)?.toInt() ?? 0;
        }
        out.add(
          KotvTrack(
            id: '$index',
            label: _metaLabel(meta, codec: codec, w: w, h: h),
          ),
        );
      } catch (_) {}
    }
    return out;
  }

  void _syncSubtitleTracks(VideoPlayerController c) {
    try {
      if (_subtitleManualOff) {
        c.setProperty('subtitle', '0');
        c.setSubtitleTracks(const []);
        return;
      }
      c.setProperty('subtitle', '1');
      if (_subtitleManualAuto && _currentSecondarySubtitleId == null) {
        return;
      }
      final tracks = <int>[];
      final primary = _parseTrackIndex(_currentSubtitleId ?? '');
      if (primary != null) tracks.add(primary);
      final secondary = _parseTrackIndex(_currentSecondarySubtitleId ?? '');
      if (secondary != null && !tracks.contains(secondary)) tracks.add(secondary);
      if (tracks.isEmpty) return;
      c.setSubtitleTracks(tracks);
    } catch (_) {}
  }

  void _applySecondaryAutoIfNeeded() {
    if (_secondarySubtitleMode == 'off' || _subtitleManualOff) return;
    if (_currentSecondarySubtitleId != null && _currentSecondarySubtitleId!.isNotEmpty) {
      return;
    }
    final c = _c;
    if (c == null || _subtitleTracks.length < 2) return;
    final primary = _parseTrackIndex(_currentSubtitleId ?? '') ??
        _parseTrackIndex(_subtitleTracks.first.id);
    for (final t in _subtitleTracks) {
      final idx = _parseTrackIndex(t.id);
      if (idx != null && idx != primary) {
        _currentSecondarySubtitleId = t.id;
        _syncSubtitleTracks(c);
        return;
      }
    }
  }

  @override
  Future<void> setStableVolume(bool on) async {
    // 实测：dynaudnorm/loudnorm 约 2s 后 AO 钟死 → 没声 + ~1fps。MPV/Exo 不受影响。
  }

  @override
  Future<void> setVideoScale(String mode) async {
    final m = mode.trim().isEmpty ? 'default' : mode.trim();
    if (_videoScale == m) return;
    _videoScale = m;
    // Surface：真实布局尺寸；Texture：FittedBox。勿写无效的 video.aspect。
    _bumpView();
    notifyListeners();
  }

  @override
  Future<void> setVideoTrack(String id) async {
    final c = _c;
    if (c == null || !c.value.isInitialized) return;
    try {
      if (kotvAudioIsAuto(id) || id.trim().isEmpty) {
        final info = c.getMediaInfo() as dynamic;
        final videos = (info?.video as List?) ?? const [];
        if (videos.isEmpty) return;
        final idx = videos.first.index as int;
        c.setVideoTracks([idx]);
        _currentVideoId = '$idx';
      } else {
        final idx = _parseTrackIndex(id);
        if (idx == null) return;
        c.setVideoTracks([idx]);
        _currentVideoId = '$idx';
      }
      _refreshTracksQuiet();
      notifyListeners();
    } catch (_) {}
  }

  @override
  Future<void> setSecondarySubtitleTrack(String id) async {
    final c = _c;
    if (c == null || !c.value.isInitialized) return;
    try {
      final key = id.trim().toLowerCase();
      if (key.isEmpty || key == 'no' || key == 'off') {
        _currentSecondarySubtitleId = null;
        _syncSubtitleTracks(c);
      } else if (key == 'auto') {
        _currentSecondarySubtitleId = null;
        _applySecondaryAutoIfNeeded();
      } else {
        final idx = _parseTrackIndex(id);
        if (idx == null) return;
        _currentSecondarySubtitleId = '$idx';
        _syncSubtitleTracks(c);
      }
      _refreshTracksQuiet();
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
    final c = _c;
    if (c == null || !c.value.isInitialized) return;
    try {
      if (scale != null) {
        _subtitleFontScale = scale.clamp(0.5, 2.0);
        c.setProperty('subtitle.scale', _subtitleFontScale.toStringAsFixed(2));
      }
      if (pos != null) {
        c.setProperty('subtitle.margin', kotvSubtitlePosToMpv(pos).toStringAsFixed(1));
      }
      if (secondaryPos != null) {
        c.setProperty('subtitle2.margin', secondaryPos.clamp(0.0, 150.0).toStringAsFixed(1));
      }
      final applyLooks = forceStyle || useSystemStyle;
      if (applyLooks && color != null && color.trim().isNotEmpty) {
        c.setProperty('subtitle.color', color.trim());
      }
      if (applyLooks && borderColor != null && borderColor.trim().isNotEmpty) {
        c.setProperty('subtitle.outline_color', borderColor.trim());
      }
      if (applyLooks && borderSize != null) {
        c.setProperty('subtitle.outline', borderSize.clamp(0.0, 8.0).toStringAsFixed(1));
      }
      if (applyLooks && bgColor != null && bgColor.trim().isNotEmpty) {
        c.setProperty('subtitle.background_color', bgColor.trim());
      }
      final edge = (edgeType ?? '').trim().toLowerCase();
      final strength = ((shadowStrength ?? 50).clamp(0, 100) / 50.0).clamp(0.0, 2.5);
      if (applyLooks && edge == 'none') {
        c.setProperty('subtitle.outline', '0');
      } else if (applyLooks && edge == 'shadow') {
        c.setProperty('subtitle.shadow', (2.0 * strength).toStringAsFixed(2));
      }
      if (applyLooks && font != null && font.trim().isNotEmpty && font.trim().toLowerCase() != 'default') {
        c.setProperty('subtitle.font', font.trim());
      }
      if (forceStyle) {
        c.setProperty('subtitle.force', '1');
      }
    } catch (_) {}
  }

  @override
  Future<void> setSubtitleOffsetMs(int offsetMs) async {
    final c = _c;
    if (c == null || !c.value.isInitialized) return;
    try {
      // mpv 风格：秒
      final sec = offsetMs.clamp(-300000, 300000) / 1000.0;
      c.setProperty('subtitle.delay', sec.toStringAsFixed(3));
    } catch (_) {}
  }

  @override
  Future<void> addSubtitleFile(String path, {String? title}) async {
    final c = _c;
    if (c == null || !c.value.isInitialized) return;
    final uri = path.trim();
    if (uri.isEmpty) return;
    try {
      c.setExternalSubtitle(uri);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (!identical(_c, c)) return;
      _refreshTracksQuiet();
      if (_subtitleTracks.isNotEmpty) {
        await setSubtitleTrack(_subtitleTracks.last.id);
      }
      notifyListeners();
    } catch (_) {}
  }

  @override
  Future<void> setAudioTrack(String id) async {
    final c = _c;
    if (c == null || !c.value.isInitialized) return;
    try {
      if (kotvAudioIsAuto(id)) {
        _currentAudioId = null;
        notifyListeners();
        return;
      }
      final idx = _parseTrackIndex(id);
      if (idx == null) return;
      c.setAudioTracks([idx]);
      _currentAudioId = '$idx';
      _refreshTracksQuiet();
      notifyListeners();
    } catch (_) {}
  }

  @override
  Future<void> setSubtitleTrack(String id) async {
    final c = _c;
    if (c == null || !c.value.isInitialized) return;
    try {
      if (id.trim().isEmpty || kotvSubtitleIsOff(id)) {
        _subtitleManualOff = true;
        _subtitleManualAuto = false;
        _currentSubtitleId = null;
        _currentSecondarySubtitleId = null;
        c.setProperty('subtitle', '0');
        c.setSubtitleTracks(const []);
      } else if (kotvSubtitleIsAuto(id)) {
        _subtitleManualOff = false;
        _subtitleManualAuto = true;
        _currentSubtitleId = null;
        c.setProperty('subtitle', '1');
        c.setSubtitleTracks(const []);
        _applySecondaryAutoIfNeeded();
      } else {
        _subtitleManualOff = false;
        _subtitleManualAuto = false;
        final idx = _parseTrackIndex(id);
        if (idx == null) return;
        _currentSubtitleId = '$idx';
        _syncSubtitleTracks(c);
      }
      _refreshTracksQuiet();
      notifyListeners();
    } catch (_) {}
  }

  @override
  void dispose() {
    _viewGen.dispose();
    unawaited(() async {
      try {
        await stop();
      } catch (_) {}
      try {
        await _posCtrl.close();
      } catch (_) {}
      try {
        await _bufCtrl.close();
      } catch (_) {}
      try {
        await _doneCtrl.close();
      } catch (_) {}
    }());
    super.dispose();
  }
}
