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
import 'silent_video_guard.dart';
import 'video_eq.dart';

/// 页内 FVP（libmdk）：经 [video_player] + fvp 插件。
///
/// 须在首次使用 FVP 前调用 [kotvEnsureFvpRegistered]（见 [kotvRegisterFvp]）。
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
  String _videoScale = 'default';
  List<KotvTrack> _audioTracks = const [];
  List<KotvTrack> _videoTracks = const [];
  List<KotvTrack> _subtitleTracks = const [];
  String? _currentAudioId;
  String? _currentVideoId;
  String? _currentSubtitleId;
  String? _currentSecondarySubtitleId;
  bool _subtitleManualOff = false;
  bool _subtitleManualAuto = false;
  String _secondarySubtitleMode = 'off';
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
  bool _audioLoudness = false;
  int _audioCenterGain = 0;
  String _audioChannelMode = 'auto';
  int _audioOffsetMs = 0;

  VideoPlayerController? get controller => _c;

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
    // 未出尺寸前占满父级，保证 Windows Texture 有非零面积（FittedBox+0x0 会一直黑）。
    final sz = c.value.size;
    if (!c.value.isInitialized || sz.width <= 0 || sz.height <= 0) {
      return ColoredBox(
        color: Colors.black,
        child: SizedBox.expand(child: VideoPlayer(c)),
      );
    }
    return FittedBox(
      fit: fit,
      child: SizedBox(
        width: sz.width,
        height: sz.height,
        child: VideoPlayer(c),
      ),
    );
  }

  /// 摘掉 listener 后走统一拆机：pause → 排空 → dispose（超时丢后台，避免卡死 open）。
  Future<void> _disposeController() async {
    final c = _c;
    final l = _listener;
    _c = null;
    _listener = null;
    if (c == null) return;
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
      },
      dispose: () async {
        await c.dispose();
      },
      drain: const Duration(milliseconds: 400),
      disposeTimeout: const Duration(milliseconds: 600),
    );
  }

  @override
  Future<void> open(
    String url, {
    Map<String, String>? headers,
    Map<String, dynamic>? drm,
    bool live = false,
  }) async {
    kotvEnsureFvpRegistered();
    final clearKeyHex = kotvIsLocalClearKey(drm) ? kotvClearKeyHex(drm) : null;
    if (drm != null && '${drm['type'] ?? ''}'.trim().isNotEmpty && clearKeyHex == null) {
      throw UnsupportedError('DRM 内容请使用内置 ExoPlayer');
    }
    _opening = true;
    _live = live;
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
      // 302 交给 mdk 默认 IO 跟跳（未强制 io.avio）。
      final c = VideoPlayerController.networkUrl(
        Uri.parse(url),
        httpHeaders: h,
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );
      _c = c;
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
        notifyListeners();
      };
      c.addListener(_listener!);
      // initialize 前写入解码器列表（硬/软锁死；自动=硬解优先+软解回退）。
      _applyDecodeMode(c);
      if (clearKeyHex != null) {
        try {
          c.setProperty('demux.lavf.o', kotvLavfOWithClearKey(clearKeyHex));
        } catch (_) {
          try {
            c.setProperty('avio.dict', 'decryption_key=$clearKeyHex');
          } catch (_) {}
        }
      }
      // 先让父级 rebuild 挂上 VideoPlayer，再 initialize。
      notifyListeners();
      await SchedulerBinding.instance.endOfFrame;
      await Future<void>.delayed(const Duration(milliseconds: 32));
      await c.initialize();
      if (c.value.hasError) {
        _lastError = c.value.errorDescription ?? 'FVP initialize 失败';
        throw StateError(_lastError!);
      }
      // 点播才套 KotvBufferBudget；直播（页面 live 或 isLive）勿猛囤——直播此处只是跳过点播预读。
      try {
        final engineLive = () {
          try {
            return c.isLive();
          } catch (_) {
            return false;
          }
        }();
        if (live || engineLive) {
          // 桌面直播：4s 太容易欠载停住；drop 保持追直播沿，类似 MPV cache-pause=no。
          final liveMax = kotvIsDesktop() ? 8000 : 4000;
          c.setBufferRange(min: 0, max: liveMax, drop: true);
        } else {
          await KotvBufferBudget.warm();
          final maxMs = KotvBufferBudget.fvpMaxBufferMs(KotvBufferBudget.bytes());
          c.setBufferRange(min: 1000, max: maxMs);
        }
      } catch (_) {}
      await c.setVolume((_volume / 100).clamp(0, 1));
      await c.setPlaybackSpeed(_rate);
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
    await _c?.seekTo(d);
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
    _applyDecodeMode(_c);
  }

  void _applyDecodeMode(VideoPlayerController? c) {
    if (c == null) return;
    try {
      c.setVideoDecoders(kotvFvpVideoDecoders(_decodeMode));
    } catch (_) {}
  }

  void applyPlayerOptions(Map<String, dynamic> settings) {
    _subtitleFontScale = double.tryParse('${settings['subtitleFontScale'] ?? '1.0'}') ?? 1.0;
    _subtitleFontScale = _subtitleFontScale.clamp(0.5, 2.5);
    final sec = '${settings['exoSecondarySubtitle'] ?? 'default'}'.trim().toLowerCase();
    _secondarySubtitleMode = (sec == 'auto' || sec == 'on' || sec == 'manual' || sec == 'default' || sec == 'player')
        ? (sec == 'on' ? 'auto' : (sec == 'player' ? 'default' : sec))
        : 'default';
    _preferredTextLangs = '${settings['exoPreferredTextLangs'] ?? ''}'.trim();
    _videoEq = KotvVideoEq.fromSettings(settings);
    _audioEq = kotvAudioEqFromSettings(settings);
    _audioEqBands = kotvAudioEqBandsFromSettings(settings);
    _audioDialogue = kotvAudioDialogueFromSettings(settings);
    _audioBalance = kotvAudioBalanceFromSettings(settings);
    _audioStability = kotvAudioStabilityFromSettings(settings);
    _audioBoost = kotvAudioBoostFromSettings(settings);
    _audioPreamp = kotvAudioPreampFromSettings(settings);
    _audioLoudness = kotvAudioLoudnessFromSettings(settings);
    _audioCenterGain = kotvAudioCenterGainFromSettings(settings);
    _audioChannelMode = kotvAudioChannelModeFromSettings(settings);
    _audioOffsetMs = kotvAudioOffsetMsFromSettings(settings);
    _applyRuntimeOptions(_c);
    _applySecondaryAutoIfNeeded();
    notifyListeners();
  }

  void _applyRuntimeOptions(VideoPlayerController? c) {
    if (c == null || !c.value.isInitialized) return;
    try {
      c.setProperty('subtitle.scale', _subtitleFontScale.toStringAsFixed(2));
      if (_preferredTextLangs.isNotEmpty) {
        c.setProperty('subtitle.language', _preferredTextLangs);
      }
      final vf = _videoEq.fvpAvfilter();
      c.setProperty('video.avfilter', vf);
      final af = kotvAudioEqFvpFilter(
        _audioEq,
        bands: _audioEqBands,
        dialogue: _audioDialogue,
        balance: _audioBalance,
        channelMode: _audioChannelMode,
        stability: _audioStability,
        boost: _audioBoost,
        preamp: _audioPreamp,
        loudness: _audioLoudness,
        centerGain: _audioCenterGain,
      );
      c.setProperty('audio.avfilter', af);
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

  void _refreshTracksQuiet() {
    final c = _c;
    if (c == null || !c.value.isInitialized) return;
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
    final c = _c;
    if (c == null || !c.value.isInitialized) return;
    try {
      c.setProperty('audio.avfilter', on ? 'dynaudnorm=f=75:g=15:p=0.55' : '');
    } catch (_) {
      try {
        c.setProperty('audio.avfilter', on ? 'loudnorm' : '');
      } catch (_) {}
    }
  }

  @override
  Future<void> setVideoScale(String mode) async {
    final m = mode.trim().isEmpty ? 'default' : mode.trim();
    _videoScale = m;
    final c = _c;
    if (c == null || !c.value.isInitialized) return;
    try {
      switch (m.toLowerCase()) {
        case '16:9':
          c.setProperty('video.aspect', '16/9');
        case '4:3':
          c.setProperty('video.aspect', '4/3');
        case 'fill':
        case 'zoom':
          c.setProperty('video.aspect', '-1');
        default:
          c.setProperty('video.aspect', '0');
      }
    } catch (_) {}
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
        _subtitleFontScale = scale.clamp(0.5, 2.5);
        c.setProperty('subtitle.scale', _subtitleFontScale.toStringAsFixed(2));
      }
      if (pos != null) {
        c.setProperty('subtitle.margin', pos.clamp(0.0, 150.0).toStringAsFixed(1));
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
