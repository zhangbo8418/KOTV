import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'buffer_budget.dart';
import 'keep_awake.dart';
import 'kotv_platform.dart';
import 'mpv_opts.dart';
import 'play_headers.dart';
import 'silent_video_guard.dart';

/// 统一播放后端：MPV(media_kit) 共用同一套菜单/控件。
abstract class KotvPlayback extends ChangeNotifier {
  bool? _keepAwakeWant;

  bool get playing;
  bool get completed;
  Duration get position;
  Duration get duration;
  /// 已缓冲到的位置（用于进度条 secondary track）；未知时为 zero。
  Duration get buffered => Duration.zero;
  /// 是否正在缓冲（卡顿补缓冲 / 起播缓冲）。
  bool get buffering => false;
  /// 估算下载速度（字节/秒）；0 表示未知。
  int get networkSpeedBps => 0;
  double get volume; // 0–100
  double get rate;
  int get width;
  int get height;
  String get engineLabel;

  Stream<Duration> get positionStream;

  /// 缓冲位置变化（可选；UI 也可靠 [ChangeNotifier]）。
  Stream<Duration> get bufferedStream => const Stream<Duration>.empty();

  /// 本集自然播完（非手动 stop）时发出 true。
  Stream<bool> get completedStream;

  Future<void> open(String url, {Map<String, String>? headers, Map<String, dynamic>? drm});
  Future<void> playOrPause();
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration d);
  Future<void> setVolume(double v);
  Future<void> setRate(double r);
  Future<void> setRepeatOne(bool on);
  Future<void> setDecodeMode(String mode);

  /// 是否认为已挂上可用视频源（轨/元数据）。无法判断时返回 true。
  bool get hasVideoSourceHint => true;

  /// 已确认是纯音频（无视频轨且有音轨）；此时不应要求出画面。
  bool get isAudioOnlyContent => false;

  /// 尝试修复视源：能枚举轨的引擎应重选视频轨；否则软重试（seek/play）。
  Future<void> tryFixVideoSource() async {}

  /// 当前片源可切换的真实音轨（不含 media_kit 注入的 `auto` / `no` 控制项）。
  List<KotvTrack> get audioTracks;
  /// 当前片源可切换的真实字幕轨（同上；关闭/自动请用 [setSubtitleTrack]）。
  List<KotvTrack> get subtitleTracks;
  String? get currentAudioId;
  String? get currentSubtitleId;
  Future<void> setAudioTrack(String id);
  Future<void> setSubtitleTrack(String id); // ''=关, 'auto'=自动

  /// 播放或缓冲中保持屏幕常亮；暂停/停止/销毁时释放。
  void _syncKeepAwake() {
    final want = playing || buffering;
    if (_keepAwakeWant == want) return;
    _keepAwakeWant = want;
    KotvKeepAwake.setHolding(this, want);
  }

  @override
  void notifyListeners() {
    _syncKeepAwake();
    super.notifyListeners();
  }

  @override
  void dispose() {
    if (_keepAwakeWant == true) {
      _keepAwakeWant = false;
      KotvKeepAwake.setHolding(this, false);
    }
    super.dispose();
  }
}

/// 网速文案：统一两位小数，如 `0.00 KB/s` / `12.34 KB/s` / `100.00 MB/s`。
/// [showZero] 为 true 时，0 也显示（缓冲界面用来判断是否卡死）。
String kotvFormatSpeed(int bytesPerSec, {bool showZero = false}) {
  if (bytesPerSec <= 0) return showZero ? '0.00 KB/s' : '';
  final kb = bytesPerSec / 1024.0;
  if (kb < 1024) {
    return '${kb.toStringAsFixed(2)} KB/s';
  }
  return '${(kb / 1024.0).toStringAsFixed(2)} MB/s';
}

class KotvTrack {
  const KotvTrack({required this.id, required this.label});
  final String id;
  final String label;
}

/// 安全释放 libmpv [Player]：先停播、给事件线程留出排空时间，再 dispose。
///
/// 直接 `stop()`（不 await）后立刻 `dispose()`，libmpv 的 wakeup 回调会打在
/// 已 close 的 FFI NativeCallable 上，触发
/// `Callback invoked after it has been deleted` 级别的 abort（手机表现为闪退）。
Future<void> kotvDisposeMpvPlayer(Player? player) async {
  if (player == null) return;
  try {
    await player.pause();
  } catch (_) {}
  try {
    await player.stop();
  } catch (_) {}
  // media_kit 内部还要等 event 排空；过短仍会 abort。
  await Future<void>.delayed(const Duration(milliseconds: 400));
  try {
    await player.dispose();
  } catch (_) {}
}

/// 按缓冲预算创建 [Player]，避免 media_kit 默认 32MiB 再被事后猛改造成起播抖动。
Player kotvCreateMpvPlayer() {
  final budget = KotvBufferBudget.bytes();
  return Player(
    configuration: PlayerConfiguration(
      bufferSize: budget,
      logLevel: MPVLogLevel.error,
    ),
  );
}

/// media_kit 在解析 libmpv 的 `track-list` 时，会**先插入** [AudioTrack.auto]/[SubtitleTrack.no] 等
/// 控制项（见 media_kit `real.dart`），与 demuxer 里的真实轨混在同一列表；UI 应只读 [KotvPlayback.audioTracks]。
bool kotvIsPseudoMediaTrack(String id) {
  switch (id.toLowerCase().trim()) {
    case 'auto':
    case 'no':
      return true;
    default:
      return id.trim().isEmpty;
  }
}

bool kotvSubtitleIsOff(String? id) {
  if (id == null) return true;
  switch (id.toLowerCase().trim()) {
    case '':
    case 'no':
    case 'none':
    case 'off':
      return true;
    default:
      return false;
  }
}

bool kotvSubtitleIsAuto(String? id) => (id ?? '').toLowerCase().trim() == 'auto';

bool kotvAudioIsAuto(String? id) {
  if (id == null || id.trim().isEmpty) return true;
  return id.toLowerCase().trim() == 'auto';
}

/// MPV / FVP / Exo 开播后长时间无视频尺寸（有声无画或 Texture 0×0）。
class KotvSilentVideoException implements Exception {
  const KotvSilentVideoException([this.message = '播放器无画面']);
  final String message;
  @override
  String toString() => message;
}

String _trackLabel(dynamic t) {
  if (t.title?.isNotEmpty == true) return t.title! as String;
  if (t.language?.isNotEmpty == true) return t.language! as String;
  return t.id as String;
}

/// media_kit / libmpv
class MediaKitPlayback extends KotvPlayback {
  MediaKitPlayback(this.player, {VideoController? controller, KotvMpvOpts? opts})
      : _opts = opts ?? const KotvMpvOpts(),
        controller = controller ??
            VideoController(
              player,
              configuration: (opts ?? const KotvMpvOpts()).videoControllerConfiguration(),
            ) {
    _subs.add(player.stream.playing.listen((_) => notifyListeners()));
    _subs.add(player.stream.position.listen((_) => notifyListeners()));
    _subs.add(player.stream.duration.listen((_) => notifyListeners()));
    _subs.add(player.stream.buffer.listen((_) => notifyListeners()));
    _subs.add(player.stream.buffering.listen((v) {
      _buffering = v;
      if (v) {
        unawaited(_pollCacheSpeed());
      } else {
        _speedBps = 0;
      }
      notifyListeners();
    }));
    _subs.add(player.stream.width.listen((_) => notifyListeners()));
    _subs.add(player.stream.height.listen((_) => notifyListeners()));
    _subs.add(player.stream.volume.listen((_) => notifyListeners()));
    _subs.add(player.stream.rate.listen((_) => notifyListeners()));
    _subs.add(player.stream.completed.listen((_) => notifyListeners()));
    _speedTimer = Timer.periodic(const Duration(milliseconds: 400), (_) {
      // 起播/缓冲/播放中都采：浮层 force 显示「加载中」时也要有数，不能等 buffering 才读。
      if (_buffering || player.state.buffering || player.state.playing) {
        unawaited(_pollCacheSpeed());
      }
    });
    // 必须在 open 前完成：与 VideoController 附着并行 setProperty 会卡死/闪退。
    _optsReady = _prepareOpts();
  }

  final Player player;
  final VideoController controller;
  KotvMpvOpts _opts;
  final List<StreamSubscription> _subs = [];
  String _url = '';
  Map<String, String> _headers = const {};
  bool _buffering = false;
  int _speedBps = 0;
  Timer? _speedTimer;
  bool _speedBusy = false;
  int _lastCacheBytes = -1;
  DateTime? _lastCacheAt;
  late Future<void> _optsReady;

  Future<void> _prepareOpts() async {
    // 先等 VideoController 附着，再写缓冲/hwdec，避免与 media_kit 并行 setProperty。
    try {
      final platform = player.platform;
      if (platform != null && platform.isVideoControllerAttached) {
        await platform.waitForVideoControllerInitializationIfAttached
            .timeout(const Duration(seconds: 8));
      } else {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final p2 = player.platform;
        if (p2 != null && p2.isVideoControllerAttached) {
          await p2.waitForVideoControllerInitializationIfAttached
              .timeout(const Duration(seconds: 8));
        }
      }
    } catch (_) {}
    try {
      await _opts.applyAfterAttach(player);
    } catch (_) {}
  }

  /// 等 opts + VideoController 就绪后再 open，避免起播竞态卡死。
  Future<void> _awaitReadyForOpen() async {
    try {
      await _optsReady.timeout(const Duration(seconds: 5));
    } catch (_) {}
    try {
      final platform = player.platform;
      if (platform != null && platform.isVideoControllerAttached) {
        await platform.waitForVideoControllerInitializationIfAttached
            .timeout(const Duration(seconds: 8));
      }
    } catch (_) {}
  }

  Future<void> _pollCacheSpeed() async {
    if (_speedBusy) return;
    _speedBusy = true;
    try {
      var next = 0;
      var sampled = false;
      try {
        final state = '${await (player.platform as dynamic).getProperty('demuxer-cache-state')}';
        // total-bytes / fw-bytes 会随缓冲涨落；用单调「已见最大」做差分，回落则重置。
        final fw = _parseKvInt(state, 'fw-bytes');
        final total = _parseKvInt(state, 'total-bytes');
        final bytes = (fw != null && total != null)
            ? (fw > total ? fw : total)
            : (fw ?? total);
        final now = DateTime.now();
        if (bytes != null) {
          final prevAt = _lastCacheAt;
          final prev = _lastCacheBytes;
          if (prevAt != null && prev >= 0) {
            final dt = now.difference(prevAt).inMilliseconds;
            if (dt >= 200) {
              if (bytes >= prev) {
                final delta = bytes - prev;
                next = delta > 0 ? (((delta * 1000) / dt).round().clamp(0, 1 << 30)) : 0;
              } else {
                next = 0; // seek 后缓冲区回落
              }
              sampled = true;
              _lastCacheBytes = bytes;
              _lastCacheAt = now;
            }
          } else {
            _lastCacheBytes = bytes;
            _lastCacheAt = now;
            sampled = true;
            next = 0;
          }
        }
        // raw-input-rate：差分未采到或差分为 0 时作辅助（起播/卡缓冲常见）
        if (!sampled || next <= 0) {
          final rate = _parseKvInt(state, 'raw-input-rate');
          if (rate != null && rate > 0) {
            next = rate;
            sampled = true;
          }
        }
      } catch (_) {}
      if (!sampled || next <= 0) {
        try {
          final raw = await (player.platform as dynamic).getProperty('cache-speed');
          final v = _parseMpvBytesPerSec('$raw');
          if (v > 0) next = v;
        } catch (_) {}
      }
      if (next != _speedBps) {
        _speedBps = next < 0 ? 0 : next;
        notifyListeners();
      }
    } finally {
      _speedBusy = false;
    }
  }

  static int? _parseKvInt(String raw, String key) {
    final m = RegExp('$key\\s*[:=]\\s*(-?\\d+)', caseSensitive: false).firstMatch(raw);
    if (m != null) return int.tryParse(m.group(1)!);
    // mpv 偶发 JSON 风格 "raw-input-rate":123
    final j = RegExp('"$key"\\s*:\\s*(-?\\d+)', caseSensitive: false).firstMatch(raw);
    if (j != null) return int.tryParse(j.group(1)!);
    return null;
  }

  static int _parseMpvBytesPerSec(String raw) {
    final s = raw.trim();
    if (s.isEmpty || s == '0') return 0;
    final n = int.tryParse(s);
    if (n != null) return n;
    final m = RegExp(r'([0-9]+(?:\.[0-9]+)?)\s*([KMG]?i?B)', caseSensitive: false).firstMatch(s);
    if (m == null) {
      final only = RegExp(r'[0-9]+').firstMatch(s);
      return int.tryParse(only?.group(0) ?? '') ?? 0;
    }
    final val = double.tryParse(m.group(1)!) ?? 0;
    final unit = (m.group(2) ?? 'B').toUpperCase();
    final mul = switch (unit) {
      'KIB' || 'KB' => 1024.0,
      'MIB' || 'MB' => 1024.0 * 1024.0,
      'GIB' || 'GB' => 1024.0 * 1024.0 * 1024.0,
      _ => 1.0,
    };
    return (val * mul).round();
  }

  KotvMpvOpts get opts => _opts;

  /// 热更新 gpu-next / conf / 解码：全部走 mpv 属性，不重建 VideoController。
  Future<void> applyMpvOpts(KotvMpvOpts next, {bool reopen = false}) async {
    final voChanged = next.gpuNext != _opts.gpuNext || next.decodeMode != _opts.decodeMode;
    _opts = next;
    if (voChanged) {
      try {
        await (player.platform as dynamic).setProperty('hwdec', next.hwdecValue());
      } catch (_) {}
      if (kotvIsAndroid()) {
        try {
          await (player.platform as dynamic)
              .setProperty('vo', next.gpuNext ? 'gpu-next' : 'gpu');
        } catch (_) {}
      }
    }
    await next.applyAfterAttach(player);
    _optsReady = Future<void>.value();
    if (reopen && _url.isNotEmpty) {
      final pos = position;
      final wasPlaying = playing;
      await _awaitReadyForOpen();
      await player
          .open(Media(_url, httpHeaders: _headers.isEmpty ? const {} : _headers))
          .timeout(const Duration(seconds: 45));
      await player.seek(pos);
      if (wasPlaying) await player.play();
    }
    notifyListeners();
  }

  @override
  Future<void> open(String url, {Map<String, String>? headers, Map<String, dynamic>? drm}) async {
    _url = url;
    _speedBps = 0;
    _lastCacheBytes = -1;
    _lastCacheAt = null;
    // DRM 需 Exo（requiresExo）；MPV 无法解 Widevine/PlayReady
    if (drm != null && '${drm['type'] ?? ''}'.trim().isNotEmpty) {
      throw UnsupportedError('DRM 内容请使用内置 ExoPlayer');
    }
    final h = kotvNormalizePlayHeaders(headers, url: url);
    _headers = h;
    await _awaitReadyForOpen();
    // 让出一帧：Player/VC 刚建完立刻 open 时，PC 偶发卡死 UI、Android 原生 abort。
    await Future<void>.delayed(const Duration(milliseconds: 16));
    await player
        .open(Media(url, httpHeaders: h.isEmpty ? const {} : h))
        .timeout(const Duration(seconds: 45));
    await _guardSilentVideo();
  }

  bool get _videoVisible {
    // 只用 VideoController 实际输出矩形：demuxer 的 width/height 可在黑屏时非零。
    final r = controller.rect.value;
    return r != null && r.width > 1 && r.height > 1;
  }

  List<VideoTrack> _realVideoTracks() {
    return player.state.tracks.video.where((t) {
      if (kotvIsPseudoMediaTrack(t.id)) return false;
      // 封面/附件图不算正片视频轨
      if (t.image == true || t.albumart == true) return false;
      return true;
    }).toList()
      ..sort((a, b) {
        final aa = (a.w ?? 0) * (a.h ?? 0);
        final bb = (b.w ?? 0) * (b.h ?? 0);
        return bb.compareTo(aa);
      });
  }

  /// 开播画面守卫：缓冲 → 视源修复 → 黑屏窗口；解码/换播放器交给 failover。
  Future<void> _guardSilentVideo() async {
    await kotvGuardSilentVideo(
      hasVideoSize: () => _videoVisible,
      isBuffering: () => buffering,
      sessionAlive: () =>
          player.state.playing || player.state.position > Duration.zero,
      isPlaying: () => player.state.playing,
      position: () => player.state.position,
      duration: () => player.state.duration,
      isLiveContent: () {
        // media_kit 无稳定 isLive；时长 0 且已出画时由守卫按直播跳过卡死判定。
        return false;
      },
      isAudioOnly: () => isAudioOnlyContent,
      hasVideoSource: () => hasVideoSourceHint,
      onFixVideoSource: tryFixVideoSource,
    );
    if (!_videoVisible && !isAudioOnlyContent) {
      throw const KotvSilentVideoException();
    }
  }

  @override
  bool get isAudioOnlyContent {
    if (buffering) return false;
    if (_realVideoTracks().isNotEmpty) return false;
    final hasAudio =
        player.state.tracks.audio.any((t) => !kotvIsPseudoMediaTrack(t.id));
    if (!hasAudio) return false;
    // demux 已给出音轨、且没有真实视频轨 → 音乐/电台。
    return player.state.playing || player.state.position > Duration.zero;
  }

  @override
  bool get hasVideoSourceHint {
    // 纯音频：不走「修视源」失败路径。
    if (isAudioOnlyContent) return true;
    final videos = _realVideoTracks();
    if (videos.isEmpty) {
      // 轨列表未齐：先当未知有源，继续等。
      return true;
    }
    final cur = player.state.track.video;
    if (kotvIsPseudoMediaTrack(cur.id)) return false;
    if (cur.image == true || cur.albumart == true) return false;
    return true;
  }

  @override
  Future<void> tryFixVideoSource() => _reselectVideoTracks();

  Future<void> _reselectVideoTracks() async {
    final videos = _realVideoTracks();
    for (final t in videos) {
      try {
        await player.setVideoTrack(t);
        await Future<void>.delayed(const Duration(milliseconds: 350));
        if (_videoVisible) return;
      } catch (_) {}
    }
    try {
      await player.setVideoTrack(VideoTrack.auto());
      await (player.platform as dynamic).setProperty('vid', 'auto');
    } catch (_) {}
  }

  @override
  String get engineLabel => '内置 MPV';
  @override
  bool get playing => player.state.playing;
  @override
  bool get completed => player.state.completed;
  @override
  Duration get position => player.state.position;
  @override
  Duration get duration => player.state.duration;
  @override
  Duration get buffered => player.state.buffer;
  @override
  bool get buffering {
    final raw = _buffering || player.state.buffering;
    if (!raw) return false;
    // media_kit 常在 playing 时仍报 buffering（补缓存）；已出画则不当作起播缓冲。
    if (player.state.playing && _videoVisible) return false;
    return true;
  }
  @override
  int get networkSpeedBps => _speedBps;
  @override
  double get volume => player.state.volume.clamp(0, 100);
  @override
  double get rate => player.state.rate;
  @override
  int get width => player.state.width ?? controller.rect.value?.width.round() ?? 0;
  @override
  int get height => player.state.height ?? controller.rect.value?.height.round() ?? 0;
  @override
  Stream<Duration> get positionStream => player.stream.position;

  @override
  Stream<Duration> get bufferedStream => player.stream.buffer;

  @override
  Stream<bool> get completedStream => player.stream.completed;

  @override
  Future<void> playOrPause() async => player.playOrPause();
  @override
  Future<void> play() async => player.play();
  @override
  Future<void> pause() async => player.pause();
  @override
  Future<void> stop() async => player.stop();
  @override
  Future<void> seek(Duration d) async => player.seek(d);
  @override
  Future<void> setVolume(double v) async => player.setVolume(v);
  @override
  Future<void> setRate(double r) async => player.setRate(r);
  @override
  Future<void> setRepeatOne(bool on) async =>
      player.setPlaylistMode(on ? PlaylistMode.single : PlaylistMode.none);

  @override
  Future<void> setDecodeMode(String mode) async {
    await applyMpvOpts(_opts.copyWith(decodeMode: mode), reopen: _url.isNotEmpty);
  }

  @override
  List<KotvTrack> get audioTracks => player.state.tracks.audio
      .where((t) => !kotvIsPseudoMediaTrack(t.id))
      .map((t) => KotvTrack(id: t.id, label: _trackLabel(t)))
      .toList();

  @override
  List<KotvTrack> get subtitleTracks => player.state.tracks.subtitle
      .where((t) => !kotvIsPseudoMediaTrack(t.id))
      .map((t) => KotvTrack(id: t.id, label: _trackLabel(t)))
      .toList();

  @override
  String? get currentAudioId => player.state.track.audio.id;
  @override
  String? get currentSubtitleId => player.state.track.subtitle.id;

  @override
  Future<void> setAudioTrack(String id) async {
    if (id == 'auto') {
      await player.setAudioTrack(AudioTrack.auto());
      return;
    }
    for (final t in player.state.tracks.audio) {
      if (t.id == id) {
        await player.setAudioTrack(t);
        return;
      }
    }
  }

  @override
  Future<void> setSubtitleTrack(String id) async {
    if (id.isEmpty) {
      await player.setSubtitleTrack(SubtitleTrack.no());
      return;
    }
    if (id == 'auto') {
      await player.setSubtitleTrack(SubtitleTrack.auto());
      return;
    }
    for (final t in player.state.tracks.subtitle) {
      if (t.id == id) {
        await player.setSubtitleTrack(t);
        return;
      }
    }
  }

  @override
  void dispose() {
    _speedTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    // 不在这里 stop：Player 由页面持有，停播/释放统一走 [kotvDisposeMpvPlayer]，
    // 否则 stop 与随后的 dispose 抢跑会让 libmpv 回调打到已释放的 NativeCallable。
    super.dispose();
  }
}
