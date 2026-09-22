import 'dart:async';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'buffer_budget.dart';
import 'drm_opts.dart';
import 'kotv_playback.dart';
import 'mpv_diag.dart';
import 'mpv_opts.dart';
import 'play_headers.dart';
import 'silent_video_guard.dart';
import 'video_eq.dart';

/// 安全释放 libmpv [Player]：先 pause 停声，再 stop → 短排空 → dispose。
/// 各桌面平台（Win / macOS / Linux）共用 [kotvTeardownPlayback]。
/// 不改 volume：实例即将销毁，禁音反而脏掉包装类音量状态。
Future<void> kotvDisposeMpvPlayer(Player? player) async {
  if (player == null) return;
  try {
    await player.pause();
  } catch (_) {}
  await kotvTeardownPlayback(
    stop: () => player.stop(),
    dispose: () => player.dispose(),
    drain: const Duration(milliseconds: 250),
  );
}

/// 按缓冲预算创建 [Player]。
///
/// [live]=true：不套点播 KotvBufferBudget；media_kit 仅用库默认 bufferSize
///（其内部会写 demuxer-max-bytes，应用层不再二次改写）。
///
/// [conf]：用户「MPV 配置」文本，仅用于取 `kotv-log=` 决定 libmpv 日志级别
///（默认 info，落盘到 [KotvMpvDiag.fileName]）。
Player kotvCreateMpvPlayer({bool live = false, String conf = ''}) {
  final logLevel = KotvMpvDiag.logLevelFromConf(conf);
  if (live) {
    return Player(
      configuration: PlayerConfiguration(
        logLevel: logLevel,
      ),
    );
  }
  final budget = KotvBufferBudget.bytes();
  return Player(
    configuration: PlayerConfiguration(
      bufferSize: budget,
      logLevel: logLevel,
    ),
  );
}

String _trackLabel(dynamic t) {
  if (t.title?.isNotEmpty == true) return t.title! as String;
  if (t.language?.isNotEmpty == true) return t.language! as String;
  return t.id as String;
}

/// media_kit / libmpv（桌面 / iOS 等非 Android 原生插件路径）。
class MediaKitPlayback extends KotvPlayback {
  /// [live]=true：构造期 [_prepareOpts] 就跳过点播 demuxer（直播页必须传，避免先写入点播预算）。
  MediaKitPlayback(
    this.player, {
    VideoController? controller,
    KotvMpvOpts? opts,
    bool live = false,
  })  : _opts = opts ?? const KotvMpvOpts(),
        _live = live,
        controller = controller ??
            VideoController(
              player,
              configuration: (opts ?? const KotvMpvOpts()).videoControllerConfiguration(),
            ) {
    _subs.add(player.stream.playing.listen((_) => notifyListeners()));
    // 进度走 positionStream 直通 player.stream.position；勿每帧 notifyListeners。
    _subs.add(player.stream.duration.listen((_) => notifyListeners()));
    _subs.add(player.stream.buffer.listen((_) => notifyListeners()));
    _subs.add(player.stream.buffering.listen((v) {
      _buffering = v;
      if (!v) _speedBps = 0;
      notifyListeners();
    }));
    _subs.add(player.stream.width.listen((w) {
      if (!_acceptSize) return;
      _w = w ?? 0;
      notifyListeners();
    }));
    _subs.add(player.stream.height.listen((h) {
      if (!_acceptSize) return;
      _h = h ?? 0;
      notifyListeners();
    }));
    _subs.add(player.stream.volume.listen((_) => notifyListeners()));
    _subs.add(player.stream.rate.listen((_) => notifyListeners()));
    _subs.add(player.stream.completed.listen((_) => notifyListeners()));
    // libmpv 日志落盘（AO/VO 初始化、pause 写入等），定位桌面起播停滞。
    _diag = KotvMpvDiag.enabledFromConf(_opts.conf);
    if (_diag) {
      _subs.add(KotvMpvDiag.attach(player, tag: live ? 'live' : 'vod'));
    }
    // 网速浮层走 KotvTraffic；勿轮询 demuxer-cache-state（换集/换台重建 demuxer 时易卡音）。
    _optsReady = _prepareOpts();
  }

  bool _diag = false;
  int _openSerial = 0;

  final Player player;
  final VideoController controller;
  KotvMpvOpts _opts;
  final List<StreamSubscription> _subs = [];
  String _url = '';
  Map<String, String> _headers = const {};
  bool _buffering = false;
  bool _repeatOne = false;
  bool _live;
  int _speedBps = 0;
  late Future<void> _optsReady;
  /// 与 Exo / 原生 MPV 一致：换源时本地尺寸清零；未 [_acceptSize] 前不采信 libmpv 残留宽高。
  int _w = 0;
  int _h = 0;
  bool _acceptSize = false;
  Map<String, String> _extraOpenProps = const {};

  void setExtraOpenProps(Map<String, String> props) {
    _extraOpenProps = Map<String, String>.from(props);
  }

  void _clearVideoSize() {
    _acceptSize = false;
    _w = 0;
    _h = 0;
  }

  void _adoptPlayerSize() {
    _acceptSize = true;
    _w = player.state.width ?? 0;
    _h = player.state.height ?? 0;
  }

  /// 桌面起播：`open(play: false)` 让 media_kit 内部 `playlist-pos` 在暂停态做完，
  /// 再 [Player.play] 一次（`pause=no`）。不做轮询踢醒、不做二次兜底。
  ///
  /// **历史根因（Win7 kotv-mpv.log 实锤）：** media_kit `play()` 内部
  /// `_setPropertyFlag('pause', false)` 用 `calloc<Bool>(1)`（1 字节）承载
  /// `MPV_FORMAT_FLAG`，mpv 按 `int`（4 字节）读、`!!flag` 取值；高 3 字节是堆上
  /// 脏数据，Windows（CoTaskMemAlloc）常非零 → Dart 写 false，mpv 收到
  /// `Set property: pause=true`，于是「播放中、缓冲在涨、time-pos 不动，点一下暂停
  /// （cycle pause，无数据参数）才起播」。pub.dev 1.2.6 与上游 main 都未修，
  /// 由 `scripts/patch-media-kit.sh` 在 `flutter pub get` 后把 pub-cache 里的
  /// `calloc<Bool>(1)` 改为 `calloc<Int32>(1)`（主线 / Win7 线同版本同补丁，
  /// 打不上即中止打包）。应用层不再兜底。
  Future<void> _openThenUnpause(Media media) async {
    await player.open(media, play: false);
    await player.play();
  }

  Future<void> _prepareOpts() async {
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
      await _opts.applyAfterAttach(player, live: _live);
    } catch (_) {}
  }

  Future<void> applyOpts(KotvMpvOpts opts) async {
    _opts = opts;
    await _opts.applyAfterAttach(player, live: _live);
    notifyListeners();
  }

  @override
  String get engineLabel => '内置 MPV';

  @override
  bool get playing => player.state.playing;

  @override
  bool get completed => player.state.completed;

  @override
  bool get repeatOne => _repeatOne;

  @override
  Duration get position => player.state.position;

  @override
  Duration get duration => player.state.duration;

  @override
  Duration get buffered => player.state.buffer;

  @override
  bool get buffering => _buffering || player.state.buffering;

  @override
  int get networkSpeedBps => _speedBps;

  @override
  double get volume => player.state.volume;

  @override
  double get rate => player.state.rate;

  @override
  int get width => _w;

  @override
  int get height => _h;

  @override
  Stream<Duration> get positionStream => player.stream.position;

  @override
  Stream<Duration> get bufferedStream => player.stream.buffer;

  @override
  Stream<bool> get completedStream => player.stream.completed;

  /// media_kit 的 `Tracks` 永远带 `auto` / `no` 两个伪轨（未加载时也在），
  /// 所以不能用 `isNotEmpty` 判有无轨；只数真实轨。
  bool get _hasRealVideoTrack =>
      player.state.tracks.video.any((t) => !kotvIsPseudoMediaTrack('${t.id}'));

  bool get _hasRealAudioTrack =>
      player.state.tracks.audio.any((t) => !kotvIsPseudoMediaTrack('${t.id}'));

  /// 文件已 loaded（对应原生 MPV 的 `_ready`）：track-list 已到、或已知时长、
  /// 或已出画/进度已走。之前没有这一层，守卫 open 当刻就把 media_kit
  /// 当成「已在播却黑屏」——立刻踢 play、起 8s 黑屏窗口，慢源加载 >16s 就被误切播放器。
  bool get _loaded =>
      _hasRealVideoTrack ||
      _hasRealAudioTrack ||
      player.state.duration > Duration.zero ||
      player.state.position > Duration.zero ||
      (width > 0 && height > 0);

  @override
  bool get hasVideoSourceHint {
    // 轨表未知时不判「无视频源」，交给黑屏窗口。
    if (!_hasRealVideoTrack && !_hasRealAudioTrack) return true;
    return _hasRealVideoTrack;
  }

  @override
  bool get isAudioOnlyContent => _hasRealAudioTrack && !_hasRealVideoTrack;

  @override
  List<KotvTrack> get audioTracks {
    return player.state.tracks.audio
        .where((t) => !kotvIsPseudoMediaTrack('${t.id}'))
        .map((t) => KotvTrack(id: '${t.id}', label: _trackLabel(t)))
        .toList();
  }

  @override
  List<KotvTrack> get videoTracks {
    return player.state.tracks.video
        .where((t) => !kotvIsPseudoMediaTrack('${t.id}'))
        .map((t) => KotvTrack(id: '${t.id}', label: _trackLabel(t)))
        .toList();
  }

  @override
  List<KotvTrack> get subtitleTracks {
    return player.state.tracks.subtitle
        .where((t) => !kotvIsPseudoMediaTrack('${t.id}'))
        .map((t) => KotvTrack(id: '${t.id}', label: _trackLabel(t)))
        .toList();
  }

  @override
  String? get currentAudioId {
    final t = player.state.track.audio;
    if (t == null) return 'auto';
    return '${t.id}';
  }

  @override
  String? get currentVideoId {
    final t = player.state.track.video;
    if (t == null) return 'auto';
    return '${t.id}';
  }

  @override
  String? get currentSubtitleId {
    final t = player.state.track.subtitle;
    if (t == null) return 'no';
    return '${t.id}';
  }

  @override
  String? get currentSecondarySubtitleId => _currentSecondarySubtitleId;

  String? _currentSecondarySubtitleId;

  @override
  Future<void> open(
    String url, {
    Map<String, String>? headers,
    Map<String, dynamic>? drm,
    bool live = false,
    String? format,
  }) async {
    _url = url;
    _live = live;
    _headers = kotvNormalizePlayHeaders(headers, url: url);
    // 换源清尺寸（与 Exo / 原生 MPV 一致）；避免 libmpv 残留宽高误判就绪。
    _clearVideoSize();
    notifyListeners();
    final clearKeyHex = kotvIsLocalClearKey(drm) ? kotvClearKeyHex(drm) : null;
    if (drm != null && drm.isNotEmpty && clearKeyHex == null) {
      throw StateError('MPV 不支持该 DRM，请用内置 ExoPlayer');
    }
    await _optsReady;
    // 直播：不写 demuxer-max-bytes/cache-secs；点播才写入 KotvBufferBudget。
    await _opts.applyAfterAttach(player, live: live);
    if (clearKeyHex != null) {
      try {
        final platform = player.platform;
        if (platform != null) {
          await (platform as dynamic).setProperty('demuxer-lavf-o', kotvLavfOWithClearKey(clearKeyHex));
        }
      } catch (_) {}
    }
    if (_extraOpenProps.isNotEmpty) {
      try {
        final platform = player.platform;
        if (platform != null) {
          for (final e in _extraOpenProps.entries) {
            await (platform as dynamic).setProperty(e.key, e.value);
          }
        }
      } catch (_) {}
      _extraOpenProps = const {};
    }
    final media = Media(url, httpHeaders: _headers.isEmpty ? null : _headers);
    if (_diag) {
      KotvMpvDiag.note('open live=$live hwdec=${_opts.hwdecValue()} '
          'gpu-api=${_opts.gpuApi} ${KotvMpvDiag.hostOf(url)}');
    }
    await _openThenUnpause(media);
    if (_diag) {
      KotvMpvDiag.note('open done (play sent) dart.playing=${player.state.playing}');
      KotvMpvDiag.scheduleOpenSnapshots(player);
    }
    // 新媒开始加载后再允许采信尺寸（避免上一集残留宽高）。
    _acceptSize = true;
    _adoptPlayerSize();
    notifyListeners();
    // 与原生 MPV / Exo 一致：未 loaded 视作「未在播的缓冲」只等；loaded 后才进黑屏判定。
    // stop()/换集会重置 media_kit 状态（_loaded 回 false），必须用会话号让旧守卫
    // 看到「不缓冲且已死」而退出，否则 open() 永远不返回。
    final session = ++_openSerial;
    bool sameSession() => _openSerial == session && _url.isNotEmpty;
    await kotvGuardSilentVideo(
      hasVideoSize: () => width > 0 && height > 0,
      isBuffering: () => sameSession() && (!_loaded || buffering),
      sessionAlive: () => sameSession() && !completed && _loaded,
      isPlaying: () => playing,
      position: () => position,
      duration: () => duration,
      isLiveContent: () => live || (duration <= Duration.zero && playing),
      onFixVideoSource: tryFixVideoSource,
      isAudioOnly: () => isAudioOnlyContent,
      hasVideoSource: () => hasVideoSourceHint,
    );
  }

  @override
  Future<void> stop() async {
    // 换集只停播，不 dispose Player（离开页走 kotvDisposeMpvPlayer）。
    _url = '';
    _clearVideoSize();
    _speedBps = 0;
    if (_diag) KotvMpvDiag.note('stop');
    try {
      await player.stop();
    } catch (_) {}
    notifyListeners();
  }

  /// 换台：只暂停，保留同一 libmpv Player / Texture，等 open 换源，减轻桌面卡音。
  @override
  Future<void> stopForEpisodeSwitch() async {
    if (_diag) KotvMpvDiag.note('stopForEpisodeSwitch');
    try {
      await player.pause();
    } catch (_) {}
    notifyListeners();
  }

  @override
  Future<void> release() async {
    // 离开页：先 pause 停声，再 stop；真正 dispose 由页面 kotvDisposeMpvPlayer 完成。
    try {
      await player.pause();
    } catch (_) {}
    await stop();
  }

  /// 用户操作前后各拍一次快照：正是「点暂停/拖进度条才起播」的关键瞬间。
  Future<void> _traced(String what, Future<void> Function() action) async {
    if (!_diag) return action();
    KotvMpvDiag.note('$what dart.playing=${player.state.playing} pos=${player.state.position}');
    await KotvMpvDiag.snapshot(player, reason: 'before-$what');
    await action();
    Timer(const Duration(milliseconds: 1500), () {
      unawaited(KotvMpvDiag.snapshot(player, reason: 'after-$what+1.5s'));
    });
  }

  @override
  Future<void> playOrPause() => _traced('playOrPause', player.playOrPause);

  @override
  Future<void> play() => _traced('play', player.play);

  @override
  Future<void> pause() => _traced('pause', player.pause);

  @override
  Future<void> seek(Duration d) => _traced('seek(${d.inMilliseconds}ms)', () => player.seek(d));

  @override
  Future<void> setVolume(double v) => player.setVolume(v.clamp(0, 100));

  @override
  Future<void> setRate(double r) => player.setRate(r);

  @override
  Future<void> setRepeatOne(bool on) async {
    _repeatOne = on;
    await player.setPlaylistMode(on ? PlaylistMode.single : PlaylistMode.none);
  }

  @override
  Future<void> setDecodeMode(String mode) async {
    _opts = _opts.copyWith(decodeMode: mode);
    await applyOpts(_opts);
  }

  @override
  Future<void> setStableVolume(bool on) async {
    // 优先 dynaudnorm：loudnorm 起播后热插易卡一下并把响度猛压。
    try {
      await (player.platform as dynamic).setProperty(
        'af',
        on ? 'dynaudnorm=f=75:g=15:p=0.55' : '',
      );
    } catch (_) {
      try {
        await (player.platform as dynamic).setProperty('af', on ? 'loudnorm' : '');
      } catch (_) {}
    }
  }

  /// 桌面 libmpv：Texture 常与视口同尺寸，Flutter BoxFit 无效；须写 keepaspect/panscan/video-aspect-override。
  @override
  Future<void> setVideoScale(String mode) async {
    final m = mode.trim().isEmpty ? 'default' : mode.trim();
    switch (m.toLowerCase()) {
      case 'fill':
        await _mpvSet('keepaspect', 'no');
        await _mpvSet('panscan', '0');
        await _mpvSet('video-aspect-override', 'no');
      case 'zoom':
        await _mpvSet('keepaspect', 'yes');
        await _mpvSet('panscan', '1');
        await _mpvSet('video-aspect-override', 'no');
      case '16:9':
        await _mpvSet('keepaspect', 'yes');
        await _mpvSet('panscan', '0');
        await _mpvSet('video-aspect-override', '16:9');
      case '4:3':
        await _mpvSet('keepaspect', 'yes');
        await _mpvSet('panscan', '0');
        await _mpvSet('video-aspect-override', '4:3');
      default:
        await _mpvSet('keepaspect', 'yes');
        await _mpvSet('panscan', '0');
        await _mpvSet('video-aspect-override', 'no');
    }
  }

  @override
  Future<void> tryFixVideoSource() async {
    // open 已 prepare+play；这里只再确保 unpause，勿 seek(0)。
    if (_diag) KotvMpvDiag.note('tryFixVideoSource (silent-video guard) -> play');
    try {
      await player.play();
    } catch (_) {}
  }

  @override
  Future<void> setAudioTrack(String id) async {
    if (kotvAudioIsAuto(id)) {
      await player.setAudioTrack(AudioTrack.auto());
      return;
    }
    for (final t in player.state.tracks.audio) {
      if ('${t.id}' == id) {
        await player.setAudioTrack(t);
        return;
      }
    }
  }

  @override
  Future<void> setVideoTrack(String id) async {
    if (kotvAudioIsAuto(id) || id.isEmpty) {
      await player.setVideoTrack(VideoTrack.auto());
      return;
    }
    for (final t in player.state.tracks.video) {
      if ('${t.id}' == id) {
        await player.setVideoTrack(t);
        return;
      }
    }
  }

  @override
  Future<void> setSubtitleTrack(String id) async {
    if (id.isEmpty || kotvSubtitleIsOff(id)) {
      await player.setSubtitleTrack(SubtitleTrack.no());
      return;
    }
    if (kotvSubtitleIsAuto(id)) {
      await player.setSubtitleTrack(SubtitleTrack.auto());
      return;
    }
    for (final t in player.state.tracks.subtitle) {
      if ('${t.id}' == id) {
        await player.setSubtitleTrack(t);
        return;
      }
    }
  }

  @override
  bool get supportsDiscNav => true;

  Future<dynamic> _mpvProp(String name) async {
    try {
      final platform = player.platform;
      if (platform == null) return null;
      return await (platform as dynamic).getProperty(name);
    } catch (_) {
      return null;
    }
  }

  Future<void> _mpvSet(String name, String value) async {
    try {
      final platform = player.platform;
      if (platform == null) return;
      await (platform as dynamic).setProperty(name, value);
    } catch (_) {}
  }

  Future<void> _mpvCmd(List<String> args) async {
    try {
      final platform = player.platform;
      if (platform == null) return;
      await (platform as dynamic).command(args);
    } catch (_) {}
  }

  @override
  Future<List<KotvTrack>> discTitles() async {
    final raw = await _mpvProp('disc-titles');
    final n = int.tryParse('$raw') ?? 0;
    if (n <= 0) return const [];
    return [
      for (var i = 1; i <= n; i++) KotvTrack(id: '$i', label: '标题 $i'),
    ];
  }

  @override
  Future<List<KotvTrack>> discChapters() async {
    final raw = await _mpvProp('chapters');
    final n = int.tryParse('$raw') ?? 0;
    if (n <= 0) return const [];
    return [
      for (var i = 0; i < n; i++) KotvTrack(id: '$i', label: '章节 ${i + 1}'),
    ];
  }

  @override
  Future<void> setDiscTitle(int index) async {
    if (index < 1) return;
    await _mpvSet('disc-title', '$index');
  }

  @override
  Future<void> setDiscChapter(int index) async {
    if (index < 0) return;
    await _mpvSet('chapter', '$index');
  }

  @override
  Future<void> openDiscMenu() async {
    await _mpvCmd(const ['discnav', 'menu']);
  }

  @override
  Future<void> addSubtitleFile(String path, {String? title}) async {
    final p = path.trim();
    if (p.isEmpty) return;
    try {
      var uri = p;
      if (!p.contains('://')) {
        uri = Uri.file(p).toString();
      }
      await player.setSubtitleTrack(
        SubtitleTrack.uri(uri, title: (title ?? '').trim().isEmpty ? null : title),
      );
    } catch (_) {}
  }

  @override
  Future<void> setSecondarySubtitleTrack(String id) async {
    try {
      final platform = player.platform;
      if (platform == null) return;
      final key = id.trim().toLowerCase();
      if (key.isEmpty || key == 'no' || key == 'off' || key == 'none') {
        await (platform as dynamic).setProperty('secondary-sid', 'no');
        _currentSecondarySubtitleId = null;
      } else if (key == 'auto') {
        // 自动：选主轨以外的第一条字幕。
        final subs = subtitleTracks;
        final primary = currentSubtitleId;
        final alt = subs.where((t) => t.id != primary).toList();
        if (alt.isEmpty) {
          await (platform as dynamic).setProperty('secondary-sid', 'no');
          _currentSecondarySubtitleId = null;
        } else {
          await (platform as dynamic).setProperty('secondary-sid', alt.first.id);
          _currentSecondarySubtitleId = alt.first.id;
        }
      } else {
        await (platform as dynamic).setProperty('secondary-sid', id.trim());
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
      final platform = player.platform;
      if (platform == null) return;
      if (scale != null) {
        await (platform as dynamic).setProperty(
          'sub-scale',
          scale.clamp(0.5, 2.0).toStringAsFixed(2),
        );
      }
      if (pos != null) {
        final mpvPos = kotvSubtitlePosToMpv(pos);
        await (platform as dynamic).setProperty('sub-pos', mpvPos.toStringAsFixed(1));
      }
      if (secondaryPos != null) {
        await (platform as dynamic).setProperty(
          'secondary-sub-pos',
          secondaryPos.toStringAsFixed(1),
        );
      }
      final applyLooks = forceStyle || useSystemStyle;
      if (applyLooks && color != null && color.trim().isNotEmpty) {
        await (platform as dynamic).setProperty('sub-color', color.trim());
      }
      if (applyLooks && borderColor != null && borderColor.trim().isNotEmpty) {
        await (platform as dynamic).setProperty('sub-border-color', borderColor.trim());
      }
      if (applyLooks && borderSize != null) {
        await (platform as dynamic).setProperty(
          'sub-border-size',
          borderSize.clamp(0.0, 8.0).toStringAsFixed(1),
        );
      }
      if (applyLooks && bgColor != null && bgColor.trim().isNotEmpty) {
        await (platform as dynamic).setProperty('sub-back-color', bgColor.trim());
      }
      final edge = (edgeType ?? '').trim().toLowerCase();
      final strength = ((shadowStrength ?? 50).clamp(0, 100) / 50.0).clamp(0.0, 2.5);
      if (applyLooks && edge == 'none') {
        await (platform as dynamic).setProperty('sub-border-size', '0');
        await (platform as dynamic).setProperty('sub-shadow-offset', '0');
      } else if (applyLooks && edge == 'shadow') {
        await (platform as dynamic).setProperty('sub-shadow-offset', (2.0 * strength).toStringAsFixed(2));
      } else if (applyLooks && (edge == 'raised' || edge == 'depressed')) {
        await (platform as dynamic).setProperty('sub-shadow-offset', (1.5 * strength).toStringAsFixed(2));
      }
      if (applyLooks && font != null && font.trim().isNotEmpty && font.trim().toLowerCase() != 'default') {
        final f = font.trim().toLowerCase();
        final mpvFont = switch (f) {
          'sans' || 'sans-serif' => 'sans-serif',
          'serif' => 'serif',
          'mono' || 'monospace' => 'monospace',
          _ => font.trim(),
        };
        await (platform as dynamic).setProperty('sub-font', mpvFont);
      }
      await (platform as dynamic).setProperty('sub-ass-override', forceStyle ? 'force' : 'scale');
    } catch (_) {}
  }

  @override
  Future<void> setSubtitleOffsetMs(int offsetMs) async {
    try {
      final platform = player.platform;
      if (platform == null) return;
      final sec = (offsetMs.clamp(-300000, 300000) / 1000.0);
      await (platform as dynamic).setProperty('sub-delay', sec.toStringAsFixed(3));
    } catch (_) {}
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }
}
