import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import '../api/kotv_api.dart';
import '../api/kotv_engine_url.dart';
import '../desktop/mini_player_window.dart';
import '../models/models.dart';
import '../player/danmaku_layer.dart';
import '../player/exo_playback.dart';
import '../player/fvp_playback.dart';
import '../player/html_playback.dart';
import '../player/art_playback.dart';
import '../player/xg_playback.dart';
import '../player/zw_playback.dart';
import '../player/buffer_budget.dart';
import '../player/fullscreen_mode.dart';
import '../player/kotv_platform.dart';
import '../player/kotv_playback.dart';
import '../player/kotv_player_factory.dart';
import '../player/media_kit_playback.dart';
import '../player/mpv_opts.dart';
import '../player/native_mpv_playback.dart';
import '../player/play_headers.dart';
import '../player/playback_failover.dart';
import '../player/tv_remote_keys.dart';
import '../providers.dart';
import '../remote/local_collect.dart';
import '../remote/postmsg_host.dart';
import '../remote/remote_bridge.dart';
import '../theme/layout_scale.dart';
import '../theme/kotv_palette.dart';
import '../theme/kotv_theme.dart';
import '../widgets/buffering_overlay.dart';
import '../widgets/cast_flow.dart';
import '../widgets/chrome.dart';
import '../widgets/h_scroll.dart';
import '../widgets/kotv_network_image.dart';
import '../widgets/mini_hover_shell.dart';
import '../widgets/vod_player_chrome.dart';
import 'detail_fullscreen.dart';
import 'shell.dart';

class DetailScreen extends ConsumerStatefulWidget {
  const DetailScreen({super.key, required this.id, this.site = '', this.title = '', this.mark = ''});

  final String id;
  final String site;
  final String title;
  /// 从目录点文件时按集名匹配并起播。
  final String mark;

  /// 详情是否在栈上（含播放中 PopScope.canPop=false）。
  static bool get isOpen => _DetailScreenState._active != null;

  /// 全窗口 / 系统全屏（以页面本地状态为准，不依赖 provider 时序）。
  static bool get isImmersive => _DetailScreenState._active?._immersiveFullscreen == true;

  /// 沉浸全屏时系统返回 / 右键：只退出全屏，不出详情。
  static Future<void> exitImmersiveIfOpen() async {
    final active = _DetailScreenState._active;
    if (active == null) return;
    if (!active._immersiveFullscreen) {
      // provider 与本地状态偶发不一致时，仍清掉壳层全屏标志。
      try {
        active.ref.read(detailImmersiveFullscreenProvider.notifier).state = false;
      } catch (_) {}
      return;
    }
    await active._exitImmersiveFullscreen();
  }

  /// 刚退出全屏的短窗口内：忽略紧随其后的第二次返回（否则会出详情回首页）。
  /// Android 遥控/系统返回常同时打到 Focus 与 PopScope。
  static bool get suppressBackAfterImmersiveExit {
    final active = _DetailScreenState._active;
    if (active == null) return false;
    final until = active._suppressDetailPopUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  /// 换源/切 Tab：尽快放开 PopScope；并 await 硬停，避免卸树后 FVP/HTML 后台出声。
  static Future<void> prepareLeave() async {
    final active = _DetailScreenState._active;
    if (active == null) return;
    if (active._leaving || active._stoppedHard) {
      if (active.mounted) {
        active._allowPop = true;
        active.setState(() {});
        await WidgetsBinding.instance.endOfFrame;
      }
      return;
    }
    active._leaving = true;
    if (_DetailScreenState._active == active) {
      _DetailScreenState._active = null;
    }
    try {
      active.ref.read(detailImmersiveFullscreenProvider.notifier).state = false;
    } catch (_) {}
    active._immersiveFullscreen = false;
    try {
      await active._stopHard().timeout(const Duration(seconds: 4));
    } catch (_) {}
    if (!active.mounted) return;
    // 放开 PopScope，否则随后的 popUntil 会被 canPop:false 拦住。
    active._allowPop = true;
    active.setState(() {});
    await WidgetsBinding.instance.endOfFrame;
  }

  @override
  ConsumerState<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends ConsumerState<DetailScreen> {
  static _DetailScreenState? _active;
  VodDetail? _detail;
  String? _error;
  bool _loading = true;
  int _flagIdx = 0;
  int _epIdx = -1;
  /// 全屏页在父 setState 下更新；保留 GlobalKey 仅供自动切集动画。
  final GlobalKey<DetailFullscreenPageState> _fsPageKey = GlobalKey<DetailFullscreenPageState>();
  /// 抖音式上下滑：稳定视频层与全屏控件共用位移。
  final ValueNotifier<double> _fsSwipeDy = ValueNotifier<double>(0);
  /// 详情内嵌：菜单键弹出后播停键自动获焦。
  bool _chromeRemoteFocus = false;
  int _epPage = 0;
  bool _reversed = false;
  bool _kept = false;
  String _status = '选择剧集开始播放';
  String _playUrl = '';
  String _decodeMode = 'auto';
  /// 设置/用户所选解码；failover 临时翻转只改 [_decodeMode]。
  String _prefDecodeMode = 'auto';
  String _renderMode = 'surface';
  KotvMpvOpts _mpvOpts = const KotvMpvOpts();
  bool _danmakuOn = false;
  bool _ambientOn = false;
  bool _stableVolumeOn = false;
  String _danmakuApi = '';
  double _danmakuSize = 18;
  double _danmakuOpacity = 0.85;
  int _danmakuRows = 6;
  final ValueNotifier<List<DanmakuItem>> _danmakuItems = ValueNotifier(const []);
  AspectSpec _aspect = const AspectSpec(key: 'default', fit: BoxFit.contain);
  int _openingSec = 0;
  int _endingSec = 0;
  String _playerVal = kotvDefaultVodPlayer();
  /// 设置/用户所选播放器；failover 临时切换只改 [_playerVal]。
  String _prefPlayerVal = kotvDefaultVodPlayer();
  /// 设置「自动切换播放器」：auto=开，off=关。
  String _prefPlayerFailover = 'auto';
  bool _miniDesktop = false;
  /// 与直播页一致：原位全屏，同一 PlatformView/Texture 放大，不 push 第二块 Surface。
  bool _immersiveFullscreen = false;
  /// 全屏换集/解析中：盖住画面，避免 Surface 镂空透出底层。
  bool _immersiveEpCover = false;
  /// 退出全屏后短时挡住「再 pop 详情」，避免双通道返回直接回首页。
  DateTime? _suppressDetailPopUntil;
  KotvDesktopFullscreenKind _desktopFs = KotvDesktopFullscreenKind.window;
  final GlobalKey _videoHostKey = GlobalKey(debugLabel: 'kotv_detail_video');
  /// 量测详情页播控槽，供稳定 Positioned（Texture/PlatformView）宿主对齐。
  /// 画面在 Stack 上层、不在 ListView 子树；滚动时必须同步槽位，否则钉死在首次位置。
  final GlobalKey _videoSlotKey = GlobalKey(debugLabel: 'kotv_detail_video_slot');
  final GlobalKey _detailStackKey = GlobalKey(debugLabel: 'kotv_detail_stack');
  /// 画面层的位置由 [CompositedTransformFollower] 在合成期直接跟随黑槽
  /// （[CompositedTransformTarget]），滚动 / 窗口缩放 / 顶栏高度变化都不会错位；
  /// [_videoLayerRect] 只提供尺寸（非全屏）或整屏矩形（全屏）。
  /// 画面叠在 Scaffold 之上，必须裁到 [_bodyClipRect]（顶栏下 Expanded），
  /// 否则下滑时画面跟槽上移会盖住顶栏按钮。
  final LayerLink _videoLink = LayerLink();
  final GlobalKey _bodyClipKey = GlobalKey(debugLabel: 'kotv_detail_body_clip');
  Rect? _videoLayerRect;
  Rect? _bodyClipRect;
  bool _videoSlotSyncScheduled = false;
  /// 当前是否磁力/BT 本地流（状态文案与卡顿语义不同）。
  bool _magnetPlay = false;
  Timer? _btProgressTimer;
  static const _epSize = 20;
  double? _prefSpeed;
  double? _prefVolume;

  Player? _mkPlayer;
  KotvPlayback? _mk;
  ExoPlayback? _exo;
  FvpPlayback? _fvp;
  HtmlPlayback? _html;
  ArtPlayback? _art;
  XgPlayback? _xg;
  ZwPlayback? _zw;
  StreamSubscription? _playingSub;
  StreamSubscription? _endedSub;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription? _bufferingSub;
  KotvPlayback? _wiredNotifyTarget;
  VoidCallback? _playbackNotify;
  int? _boundMpvTextureId;
  int _lastVideoW = 0;
  int _lastVideoH = 0;
  bool _openingSeekDone = false;
  bool _stoppedHard = false;
  /// 正在离开详情（返回/切 Tab）；期间 [_active] 已清空，避免 goKotvPage 再卡硬停。
  bool _leaving = false;
  /// 硬停完成后再允许真正出栈（配合 [PopScope]）。
  bool _allowPop = false;
  /// 每次 [_playAt] 一代；仅本代真正进入可播（≈STATE_READY）后才允许自动连播。
  int _playGen = 0;
  int _playAtSerial = 0;
  /// 本代是否已消费过「播完→下一集」（completed / 片尾共用，防连跳）。
  int _endConsumedGen = -1;
  /// ≈ 在 STATE_READY 后才挂 Clock；开播/解析中为 false。
  bool _playbackLive = false;
  bool _advanceBusy = false;
  DateTime? _sessionStartedAt;
  KotvApi? _api;

  KotvEmbedBackend get _backend => kotvEmbedBackend(_playerVal);

  bool get _useMpv => _backend == KotvEmbedBackend.mpv;

  /// 当前页内后端：按设置选择 Exo / MPV / FVP / HTML。
  KotvPlayback get _playback {
    switch (_backend) {
      case KotvEmbedBackend.html:
        return _html ??= HtmlPlayback();
      case KotvEmbedBackend.art:
        return _art ??= ArtPlayback();
      case KotvEmbedBackend.xg:
        return _xg ??= XgPlayback();
      case KotvEmbedBackend.zw:
        return _zw ??= ZwPlayback();
      case KotvEmbedBackend.fvp:
        return _fvp ??= FvpPlayback();
      case KotvEmbedBackend.exo:
        return _exo ??= ExoPlayback();
      case KotvEmbedBackend.mpv:
        return _ensureMpv();
    }
  }

  String get _enginePrefix => flutterPlayerLabel(_playerVal);

  bool get _isBuffering => _playUrl.isNotEmpty && _playback.stalling;

  /// 换集/解析时 [_playUrl] 可能已清空但原生仍在播，不能单靠它判断可否 pop。
  bool get _playbackSessionActive {
    if (_allowPop) return false;
    if (_playUrl.isNotEmpty) return true;
    if (_stoppedHard) return false;
    final p = _playback;
    if (p.playing || p.buffering) return true;
    if (p.position > Duration.zero && !p.completed) return true;
    return false;
  }

  /// 是否已进入可播状态（勿等 2.5s 才改文案；出画/进度动即算开播）。
  bool _playbackStarted(KotvPlayback p) {
    if (_playbackLive) return true;
    if (p.width > 0 && p.height > 0) return true;
    if (p.position > const Duration(milliseconds: 300)) return true;
    if (p.duration > Duration.zero && p.position > Duration.zero) return true;
    if (p is NativeMpvPlayback && p.isReady && (p.playing || p.position > Duration.zero)) {
      return true;
    }
    return false;
  }

  /// 按真实播放器状态刷新文案，避免「播放中」但 00:00/00:00。
  void _syncPlayStatus() {
    if (!mounted || _playUrl.isEmpty) return;
    // 换集/解析中由 _playAt 写入固定文案，勿被 stop 后的 stream 回调盖掉。
    if (_status.contains('换集中') ||
        _status.contains('解析中') ||
        _status.contains('磁力解析') ||
        _status.contains('嗅探')) {
      return;
    }
    final p = _playback;
    final prefix = _enginePrefix;
    final magnet = _magnetPlay || _playUrl.contains('/proxy/bt/');
    final started = _playbackStarted(p);
    final effectivelyPlaying = p.playing || (started && !p.completed);
    // 网速只交给 [KotvBufferingOverlay]：写进文案会让每次测速都改字符串，
    // 从而每秒多次 setState 重建整个详情页（全屏播放明显掉帧）。
    final String next;
    if (p.completed && !p.playing) {
      next = '播放结束';
    } else if (effectivelyPlaying) {
      if (started) {
        next = magnet ? '$prefix 播放中（磁力）' : '$prefix 播放中';
      } else if (_isBuffering) {
        next = magnet ? '磁力缓冲中…' : '$prefix 缓冲中…';
      } else {
        final startedAt = _sessionStartedAt;
        if (startedAt != null && DateTime.now().difference(startedAt) > const Duration(seconds: 10)) {
          next = magnet ? '磁力无画面（可换源/换节点）' : '$prefix 无画面（可换源/解析）';
        } else {
          next = magnet ? '磁力缓冲中…' : '$prefix 加载中…';
        }
      }
    } else if (magnet && (_isBuffering || !started)) {
      next = '磁力缓冲中…';
    } else if (_isBuffering) {
      next = '$prefix 缓冲中…';
    } else {
      final startedAt = _sessionStartedAt;
      final stalled = startedAt != null &&
          DateTime.now().difference(startedAt) > const Duration(seconds: 12) &&
          p.position < const Duration(seconds: 2) &&
          p.width <= 0;
      next = stalled ? '$prefix 无法播放（可换源/解析）' : '已暂停';
    }
    if (_status == next) return;
    setState(() => _status = next);
  }

  KotvPlayback _ensureMpv() {
    if (kotvIsAndroid()) {
      _mk ??= NativeMpvPlayback(opts: _mpvOpts.copyWith(decodeMode: _decodeMode));
      return _mk!;
    }
    if (_mk != null) {
      _playingSub ??= _mkPlayer!.stream.playing.listen((_) {
        if (!mounted || _playUrl.isEmpty || !_useMpv) return;
        _markPlaybackLiveIfNeeded();
        _syncPlayStatus();
      });
      _bufferingSub ??= _mkPlayer!.stream.buffering.listen((_) {
        if (!mounted || _playUrl.isEmpty || !_useMpv) return;
        _syncPlayStatus();
      });
      return _mk!;
    }
    final player = kotvCreateMpvPlayer(conf: _mpvOpts.conf);
    _mkPlayer = player;
    _mk = MediaKitPlayback(player, opts: _mpvOpts.copyWith(decodeMode: _decodeMode));
    _playingSub = player.stream.playing.listen((_) {
      if (!mounted || _playUrl.isEmpty || !_useMpv) return;
      _markPlaybackLiveIfNeeded();
      _syncPlayStatus();
    });
    _bufferingSub = player.stream.buffering.listen((_) {
      if (!mounted || _playUrl.isEmpty || !_useMpv) return;
      _syncPlayStatus();
    });
    return _mk!;
  }

  Future<void> _stopInactiveBackends(KotvEmbedBackend keep) async {
    if (keep != KotvEmbedBackend.mpv) {
      try {
        await _mk?.stop();
      } catch (_) {}
      // Android：拆掉原生 MPV/硬解，否则切 Exo 仍占 Rockchip。
      if (kotvIsAndroid() && _mk != null) {
        try {
          _mk?.dispose();
        } catch (_) {}
        _mk = null;
      }
    }
    if (keep != KotvEmbedBackend.fvp) {
      try {
        await _fvp?.stop();
      } catch (_) {}
    }
    if (keep != KotvEmbedBackend.exo) {
      // 必须 release：仅 stop 不释放 Rockchip MediaCodec，切 MPV 会占满硬解卡死。
      try {
        await _exo?.release();
      } catch (_) {}
      try {
        _exo?.dispose();
      } catch (_) {}
      _exo = null;
    }
    if (keep != KotvEmbedBackend.html) {
      try {
        await _html?.stop();
      } catch (_) {}
    }
    if (keep != KotvEmbedBackend.art) {
      try {
        await _art?.stop();
      } catch (_) {}
    }
    if (keep != KotvEmbedBackend.xg) {
      try {
        await _xg?.stop();
      } catch (_) {}
    }
    if (keep != KotvEmbedBackend.zw) {
      try {
        await _zw?.stop();
      } catch (_) {}
    }
  }

  /// 换集/换源：解析可能要数秒，必须先停当前播放，否则上一集继续出声。
  Future<void> _stopAllBackends() async {
    // 沉浸全屏换集：保留 Surface，避免 PlatformView 卸掉后闪出底层详情。
    final keepSurface = _immersiveFullscreen;
    Future<void> stopOne(KotvPlayback? p) async {
      if (p == null) return;
      try {
        if (keepSurface) {
          await p.stopForEpisodeSwitch();
        } else {
          await p.stop();
        }
      } catch (_) {}
    }

    await Future.wait<void>([
      stopOne(_mk),
      stopOne(_fvp),
      stopOne(_exo),
      stopOne(_html),
      stopOne(_art),
      stopOne(_xg),
      stopOne(_zw),
    ]);
  }

  @override
  void initState() {
    super.initState();
    _api = ref.read(apiProvider);
    _active = this;
    kotvRegisterQuitHook(_prepareQuit);
    MiniPlayerWindow.onAndroidPipChanged = (inPip) {
      if (!mounted) return;
      setState(() => _miniDesktop = inPip);
    };
    _load();
  }

  void _syncAndroidAutoPip() {
    unawaited(MiniPlayerWindow.setAndroidAutoEnter(this, _playUrl.isNotEmpty));
  }

  Future<void> _prepareQuit() async {
    try {
      await _stopHard();
    } catch (_) {}
    final mkPlayer = _mkPlayer;
    _mkPlayer = null;
    try {
      _mk?.dispose();
    } catch (_) {}
    _mk = null;
    await kotvDisposeMpvPlayer(mkPlayer);
  }

  /// await stop，等原生停住（Win7 上 unawaited stop 不够）。
  /// 先卸画面，再 stop + release，避免 AO 残留漏音。
  /// 勿在此使用 [ref]：[_leavePage] 可能在 pop/dispose 之后仍调用本方法。
  Future<void> _stopHard() async {
    _playbackLive = false;
    _advanceBusy = false;
    _playGen++;
    _endConsumedGen = _playGen;
    // 抬起播世代：返回/停播时丢弃进行中的 play/磁力 Fetch 结果
    _playAtSerial++;
    _sessionStartedAt = null;
    _playingSub?.cancel();
    _endedSub?.cancel();
    _posSub?.cancel();
    _bufferingSub?.cancel();
    _unwirePlaybackNotify();
    _playingSub = null;
    _endedSub = null;
    _posSub = null;
    _bufferingSub = null;
    _playUrl = '';
    _magnetPlay = false;
    _stopBtProgressPoll();
    _syncAndroidAutoPip();
    // Source.stop：离开详情硬杀运行时 + 停磁力（用缓存 api，避免 dispose 后 ref 不可用）
    final api = _api;
    if (api != null) {
      unawaited(api.cancelPending(hard: true, thunder: true));
    }

    // 先卸掉 Video/PlatformView，再拆引擎（按播放器销毁顺序）。
    if (mounted) {
      setState(() {});
      await WidgetsBinding.instance.endOfFrame;
    }

    final fvp = _fvp;
    final mk = _mk;
    final exo = _exo;
    final html = _html;
    final art = _art;
    final xg = _xg;
    final zw = _zw;
    final mkPlayer = _mkPlayer;
    _fvp = null;
    _mk = null;
    _exo = null;
    _html = null;
    _art = null;
    _xg = null;
    _zw = null;
    _mkPlayer = null;

    Future<void> hardRelease(KotvPlayback? p) async {
      if (p == null) return;
      try {
        await p.release();
      } catch (_) {
        try {
          await p.stop();
        } catch (_) {}
      }
    }

    // FVP dispose 已在引擎内限时；整段硬停再封顶，避免任一后端拖死返回。
    await Future.wait<void>([
      hardRelease(fvp),
      hardRelease(mk),
      hardRelease(exo),
      hardRelease(html),
      hardRelease(art),
      hardRelease(xg),
      hardRelease(zw),
    ]).timeout(const Duration(seconds: 2), onTimeout: () => <void>[]);

    // media_kit Player 由页面持有：走 engine.release()。
    await kotvDisposeMpvPlayer(mkPlayer);

    try {
      fvp?.dispose();
    } catch (_) {}
    try {
      mk?.dispose();
    } catch (_) {}
    try {
      exo?.dispose();
    } catch (_) {}
    try {
      html?.dispose();
    } catch (_) {}
    try {
      art?.dispose();
    } catch (_) {}
    try {
      xg?.dispose();
    } catch (_) {}
    try {
      zw?.dispose();
    } catch (_) {}

    _stoppedHard = true;
  }

  Future<void> _leavePage({VoidCallback? afterPop}) async {
    if (_leaving) return;
    _leaving = true;
    // 立刻清 _active：否则 goKotvPage→prepareLeave 仍会 await 本页硬停，切 Tab 像点不动。
    if (_active == this) _active = null;
    // 先硬停再出栈：否则 Navigator.pop → dispose 里 ref 抛错时 FVP 会继续后台出声。
    try {
      await _stopHard();
    } catch (_) {}
    if (_immersiveFullscreen) {
      try {
        await _exitImmersiveFullscreen();
      } catch (_) {}
    }
    if (_miniDesktop) {
      try {
        await _exitMini();
      } catch (_) {}
    }
    if (!mounted) {
      afterPop?.call();
      return;
    }
    _allowPop = true;
    setState(() {});
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) {
      afterPop?.call();
      return;
    }
    Navigator.of(context).pop();
    afterPop?.call();
  }

  void _wireEnded(KotvPlayback p) {
    _endedSub?.cancel();
    _endedSub = p.completedStream.listen((done) {
      if (!done || !mounted) return;
      unawaited(_onPlaybackEnded());
    });
  }

  void _wirePosition(KotvPlayback p) {
    _posSub?.cancel();
    _posSub = p.positionStream.listen(_onPositionTick);
  }

  void _unwirePlaybackNotify() {
    final t = _wiredNotifyTarget;
    final cb = _playbackNotify;
    if (t != null && cb != null) {
      try {
        t.removeListener(cb);
      } catch (_) {}
    }
    _wiredNotifyTarget = null;
    _playbackNotify = null;
  }

  void _wirePlaybackNotify(KotvPlayback p) {
    _unwirePlaybackNotify();
    _playbackNotify = () {
      if (!mounted || _playUrl.isEmpty) return;
      _syncPlayStatus();
      final w = p.width;
      final h = p.height;
      final sizeChanged = w != _lastVideoW || h != _lastVideoH;
      if (sizeChanged) {
        _lastVideoW = w;
        _lastVideoH = h;
      }
      // 全屏换集黑盖：出尺寸/开播后撤掉（各平台）。
      if (_immersiveEpCover &&
          w > 0 &&
          h > 0 &&
          (sizeChanged || (p.playing && !p.stalling))) {
        setState(() => _immersiveEpCover = false);
        return;
      }
      // 仅 Android 原生 MPV：出尺寸后须 rebuild 才能按比例定 PlatformView。
      // 桌面 media_kit 的 Video 若在 open 中途因宽高 setState 整树重建，
      // 易丢 libmpv render context → 有声黑屏（此前只因 textureId 才 rebuild）。
      if (sizeChanged && p is NativeMpvPlayback) {
        setState(() {});
        return;
      }
      if (p is NativeMpvPlayback) {
        final tid = p.textureId;
        if (tid != null && tid != _boundMpvTextureId) {
          _boundMpvTextureId = tid;
          setState(() {});
        }
      }
    };
    _wiredNotifyTarget = p;
    p.addListener(_playbackNotify!);
    _playbackNotify!();
  }

  /// STATE_READY：本集真正开播后才允许片尾/completed 自动连播。
  /// 仅凭 width>0 不足（解码器探头即可有尺寸但黑屏），须进度真正前进。
  void _markPlaybackLiveIfNeeded() {
    if (_playUrl.isEmpty || _playbackLive) return;
    final p = _playback;
    if (p.completed) return;
    final pos = p.position.inMilliseconds;
    final dur = p.duration.inMilliseconds;
    // 上一集残留的近片尾进度绝不当作 READY
    if (dur > 15000 && pos >= dur - 5000 && pos > 8000) return;
    final progressed = pos >= 2500 || (dur > 0 && pos >= 1200 && p.playing);
    if (progressed && (p.playing || pos >= 2500)) {
      _playbackLive = true;
    }
  }

  /// playbackEnded / onTimeChanged→nextEpisode：每集只前进一次。
  Future<void> _advanceToNextEpisode() async {
    if (!mounted || _advanceBusy) return;
    if (!_playbackLive) return;
    if (_endConsumedGen == _playGen) return;
    final eps = _eps;
    final next = _epIdx + 1;
    if (next < 0 || next >= eps.length) {
      if (mounted) setState(() => _status = '播放结束');
      _endConsumedGen = _playGen;
      _playbackLive = false;
      return;
    }
    _endConsumedGen = _playGen;
    _playbackLive = false;
    _advanceBusy = true;
    if (mounted) setState(() => _status = '自动播放下一集…');
    try {
      if (_immersiveFullscreen) {
        await _fsPageKey.currentState?.animateAutoNext();
      }
      if (!mounted) return;
      await _playAt(next);
    } finally {
      _advanceBusy = false;
    }
  }

  /// 片头起播跳过；片尾 `ending+position>=duration` 切下一集。
  /// Clock 仅在 READY（[_playbackLive]）后生效，避免解析/换集中连跳。
  void _onPositionTick(Duration pos) {
    if (_playUrl.isEmpty || !mounted) return;
    _syncPlayStatus();
    _markPlaybackLiveIfNeeded();
    if (!_playbackLive || _endConsumedGen == _playGen) return;
    final dur = _playback.duration;
    if (dur.inMilliseconds <= 0) return;
    final openMs = _openingSec * 1000;
    final endMs = _endingSec * 1000;
    if (openMs > 0 && !_openingSeekDone) {
      if (pos.inMilliseconds + 800 < openMs) {
        _openingSeekDone = true;
        unawaited(_playback.seek(Duration(milliseconds: openMs)));
        return;
      }
      if (pos.inMilliseconds >= openMs) _openingSeekDone = true;
    }
    // ending > 0 && ending + position >= duration
    if (endMs > 0 && pos.inMilliseconds + endMs >= dur.inMilliseconds) {
      _openingSeekDone = false;
      unawaited(_advanceToNextEpisode());
    }
  }

  Future<void> _onPlaybackEnded() async {
    if (!mounted) return;
    _markPlaybackLiveIfNeeded();
    if (!_playbackLive || _endConsumedGen == _playGen) return;
    final pos = _playback.position.inMilliseconds;
    final dur = _playback.duration.inMilliseconds;
    // 黑屏/假结束：几乎没播过就不自动下一集
    if (pos < 8000) return;
    if (dur > 0) {
      final nearEnd = pos + 8000 >= dur || pos >= (dur * 0.92).round();
      if (!nearEnd) return;
    }
    await _advanceToNextEpisode();
  }

  @override
  void deactivate() {
    // dispose 不能用 ref。仅在「本地已退出沉浸」时清壳层标志。
    // 若仍 _immersiveFullscreen 却在这里清 provider，底栏/SafeArea 会立刻回来，
    // 竖屏全屏画面按 MediaQuery 整屏高居中就会偏下，也不像沉浸。
    if (!_immersiveFullscreen) {
      try {
        ref.read(detailImmersiveFullscreenProvider.notifier).state = false;
      } catch (_) {}
    }
    super.deactivate();
  }

  @override
  void dispose() {
    // 勿在此处 ref.read：会抛 Bad state，打断后面的 FVP/播放器 stop。
    kotvUnregisterQuitHook(_prepareQuit);
    if (_active == this) _active = null;
    MiniPlayerWindow.onAndroidPipChanged = null;
    unawaited(MiniPlayerWindow.setAndroidAutoEnter(this, false));
    // 离开详情：回传扫码取消并打断 JAR；不要再 nav.pop（本页正在出栈）。
    final api = _api;
    if (api != null) {
      unawaited(PostMsgHost.instance?.cancelAll(reply: true, popDialog: false) ?? Future<void>.value());
      unawaited(api.cancelPending(hard: true, thunder: true));
    }
    if (_miniDesktop) {
      unawaited(MiniPlayerWindow.exit());
    }
    _playingSub?.cancel();
    _endedSub?.cancel();
    _posSub?.cancel();
    _bufferingSub?.cancel();
    _unwirePlaybackNotify();
    _stopBtProgressPoll();
    _danmakuItems.dispose();
    _fsSwipeDy.dispose();
    // 正常路径已在 [_stopHard] 里 await release；引擎引用已清空。
    // 异常路径（未走 _leavePage）仍兜底停+释放，避免漏音。
    if (!_stoppedHard) {
      unawaited(() async {
        try {
          await _fvp?.release();
        } catch (_) {}
        try {
          await _mk?.release();
        } catch (_) {}
        try {
          await _exo?.release();
        } catch (_) {}
        try {
          await _html?.release();
        } catch (_) {}
        try {
          await _art?.release();
        } catch (_) {}
        try {
          await _xg?.release();
        } catch (_) {}
        try {
          await _zw?.release();
        } catch (_) {}
      }());
    }
    _fvp?.dispose();
    _mk?.dispose();
    _exo?.dispose();
    _html?.dispose();
    _art?.dispose();
    _xg?.dispose();
    _zw?.dispose();
    final mkPlayer = _mkPlayer;
    _mkPlayer = null;
    _mk = null;
    _fvp = null;
    _exo = null;
    _html = null;
    _art = null;
    _xg = null;
    _zw = null;
    unawaited(kotvDisposeMpvPlayer(mkPlayer));
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await ref.read(apiProvider).detail(id: widget.id, site: widget.site);
      final vod = VodDetail.fromJson(Map<String, dynamic>.from(data['vod'] as Map));
      final kept = await LocalCollect.isKept(
        vod.id.isNotEmpty ? vod.id : widget.id,
        vod.site.isNotEmpty ? vod.site : widget.site,
      );
      try {
        final st = await ref.read(apiProvider).getSettings();
        final settings = Map<String, dynamic>.from((st['settings'] as Map?) ?? const {});
        final decode = '${settings['playerDecode'] ?? 'auto'}';
        if (decode.isNotEmpty) {
          _decodeMode = decode;
          _prefDecodeMode = decode;
        }
        _renderMode = kotvNormalizePlayerRender('${settings['playerRender'] ?? 'surface'}');
        _mpvOpts = KotvMpvOpts.fromSettings(settings, decodeMode: _decodeMode);
        _danmakuOn = '${settings['danmaku'] ?? ''}'.toLowerCase() == 'true';
        _ambientOn = '${settings['playerAmbient'] ?? ''}'.toLowerCase() == 'true';
        _stableVolumeOn = '${settings['playerStableVolume'] ?? ''}'.toLowerCase() == 'true';
        _danmakuApi = '${settings['danmakuApi'] ?? ''}';
        _danmakuSize = double.tryParse('${settings['danmakuSize'] ?? ''}') ?? 18;
        final op = double.tryParse('${settings['danmakuOpacity'] ?? ''}');
        _danmakuOpacity = op == null ? 0.85 : (op > 1 ? op / 100.0 : op).clamp(0.15, 1.0);
        _danmakuRows = int.tryParse('${settings['danmakuRows'] ?? ''}') ?? 6;
        final scale = '${settings['playerScale'] ?? 'default'}';
        _aspect = _aspectFromScale(scale);
        unawaited(_playback.setVideoScale(_aspect.key));
        var playerVal = '${settings['player'] ?? kotvDefaultVodPlayer()}'.trim();
        if (playerVal.isEmpty) {
          playerVal = kotvDefaultVodPlayer();
        }
        _playerVal = kotvClampPlayerVal(playerVal, live: false);
        _prefPlayerVal = _playerVal;
        final failoverMode = '${settings['playerFailover'] ?? 'auto'}'.trim().toLowerCase();
        _prefPlayerFailover = (failoverMode == 'off' || failoverMode == 'false') ? 'off' : 'auto';
        // 绝不在进详情时创建原生播放器：初始化会卡死 UI / 手机闪退。
        // 音量/倍速等偏好先记下，真正 [_playAt] open 后再套。
        _prefSpeed = double.tryParse('${settings['playerSpeed'] ?? ''}');
        _prefVolume = double.tryParse('${settings['playerVolume'] ?? ''}');
        kotvApplyPlayUaSetting('${settings['ua'] ?? ''}');
        unawaited(KotvBufferBudget.warm());
      } catch (_) {}
      setState(() {
        _detail = vod;
        _kept = kept;
        _loading = false;
      });
      _applyFolderMark();
      final id = vod.id.isNotEmpty ? vod.id : widget.id;
      final site = vod.site.isNotEmpty ? vod.site : widget.site;
      final off = await LocalPlayOffsets.get(id, site);
      if (mounted) {
        setState(() {
          _openingSec = off.$1;
          _endingSec = off.$2;
        });
      }
      final needExpand = data['magnet'] == true || _detailHasMagnet(vod);
      if (needExpand && mounted) {
        unawaited(_expandMagnet(id: id, site: site));
      }
    } catch (e) {
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  bool _detailHasMagnet(VodDetail vod) {
    for (final f in vod.flags) {
      for (final ep in f.episodes) {
        final u = ep.url.trim().toLowerCase();
        if (u.startsWith('magnet:') || u.startsWith('thunder:') || u.startsWith('ed2k:') || u.contains('.torrent')) {
          return true;
        }
      }
    }
    return false;
  }

  Future<void> _expandMagnet({required String id, required String site}) async {
    if (!mounted) return;
    final cur = _detail;
    if (cur == null) return;
    // 已在播非磁力：展开只更新列表，不抢状态栏、不清选集
    final playingNonMagnet = _playUrl.isNotEmpty && !_magnetPlay;
    if (!playingNonMagnet) {
      setState(() => _status = '正在展开磁力文件…');
    }
    _startBtProgressPoll(expanding: true);
    try {
      final flagsPayload = cur.flags
          .map((f) => {
                'flag': f.flag,
                'show': f.show,
                'episodes': f.episodes.map((e) => {'name': e.name, 'url': e.url}).toList(),
              })
          .toList();
      final data = await ref.read(apiProvider).detailExpand(id: id, site: site, flags: flagsPayload);
      if (!mounted) return;
      if (data['expanded'] == true && data['vod'] is Map) {
        final expanded = VodDetail.fromJson(Map<String, dynamic>.from(data['vod'] as Map));
        // 只替换线路/剧集，保留当前详情其它字段，避免整页重建冲掉扫码等弹窗。
        setState(() {
          _detail = cur.withFlags(expanded.flags);
          if (_flagIdx >= expanded.flags.length) _flagIdx = 0;
          _epPage = 0;
          if (!playingNonMagnet && _epIdx >= 0) _epIdx = -1;
          if (!playingNonMagnet) {
            _status = '磁力文件已展开，可选集播放';
          }
        });
      } else if (mounted && !playingNonMagnet) {
        setState(() => _status = '选择剧集开始播放');
      }
    } catch (e) {
      if (mounted && !playingNonMagnet) setState(() => _status = '磁力展开失败，仍可点原链起播');
    } finally {
      _stopBtProgressPoll();
    }
  }

  void _startBtProgressPoll({bool expanding = false}) {
    _btProgressTimer?.cancel();
    _btProgressTimer = Timer.periodic(const Duration(milliseconds: 600), (_) async {
      if (!mounted) return;
      try {
        final p = await ref.read(apiProvider).btProgress();
        final msg = '${p['message'] ?? ''}'.trim();
        if (msg.isEmpty || !mounted) return;
        // 展开过程中若已在播非磁力，绝不抢状态栏。
        if (expanding && _playUrl.isNotEmpty && !_magnetPlay) return;
        // 「已取消」来自 thunder.Stop；非磁力播放时忽略，避免误显示。
        if (msg == '已取消' && !_magnetPlay) return;
        // 展开/起播过程中用引擎进度覆盖状态；已进入正式播放文案则不抢。
        if (_status.contains('播放中') && !_status.contains('磁力缓冲')) return;
        if (_status == '已暂停' || _status == '播放结束' || _status.startsWith('播放失败')) return;
        if (expanding || _magnetPlay || _status.contains('磁力') || _status.contains('解析') || _status.contains('缓冲') || _status.contains('加载')) {
          if (_status != msg) setState(() => _status = msg);
        }
      } catch (_) {}
    });
  }

  void _stopBtProgressPoll() {
    _btProgressTimer?.cancel();
    _btProgressTimer = null;
  }

  List<EpisodeItem> get _eps {
    final d = _detail;
    if (d == null || d.flags.isEmpty) return const [];
    final flag = d.flags[_flagIdx.clamp(0, d.flags.length - 1)];
    final list = List<EpisodeItem>.from(flag.episodes);
    return _reversed ? list.reversed.toList() : list;
  }

  String? _currentEpisodeName() {
    final eps = _eps;
    if (_epIdx >= 0 && _epIdx < eps.length) return eps[_epIdx].name;
    return null;
  }

  /// 按集名 / 集号匹配，不按「第 N 个」。
  int _matchEpisodeIndex(List<EpisodeItem> eps, String remarks) {
    if (eps.isEmpty) return -1;
    if (eps.length == 1) return 0;
    final want = remarks.trim();
    if (want.isEmpty) return -1;
    final wantNum = _episodeNumber(want);
    var best = -1;
    var bestScore = 0;
    for (var i = 0; i < eps.length; i++) {
      final name = eps[i].name.trim();
      var score = 0;
      if (name.toLowerCase() == want.toLowerCase()) {
        score = 100;
      } else if (wantNum != -1 && _episodeNumber(name) == wantNum) {
        score = 80;
      } else if (wantNum == -1 && want.length >= 2 && name.toLowerCase().contains(want.toLowerCase())) {
        score = 70;
      } else if (wantNum == -1 && name.length >= 2 && want.toLowerCase().contains(name.toLowerCase())) {
        score = 60;
      }
      if (score > bestScore) {
        bestScore = score;
        best = i;
      }
    }
    if (best >= 0) return best;
    if (_epIdx >= 0 && _epIdx < eps.length) return _epIdx;
    return -1;
  }

  /// 从目录点文件：按 mark 匹配集名并自动起播。
  void _applyFolderMark() {
    final mark = widget.mark.trim();
    if (mark.isEmpty) return;
    final eps = _eps;
    if (eps.isEmpty) return;
    var idx = _matchEpisodeIndex(eps, mark);
    if (idx < 0) idx = 0;
    _epIdx = idx;
    _epPage = idx ~/ _epSize;
    unawaited(_playAt(idx));
  }

  static int _episodeNumber(String name) {
    final m = RegExp(r'(\d+)').firstMatch(name);
    if (m == null) return -1;
    return int.tryParse(m.group(1) ?? '') ?? -1;
  }

  /// 换线路：立刻切列表并按集名保留当前集。
  void _selectFlag(int i, {bool autoPlay = true}) {
    final d = _detail;
    if (d == null || d.flags.isEmpty) return;
    if (i < 0 || i >= d.flags.length) return;
    final remarks = _currentEpisodeName() ?? '';
    _flagIdx = i;
    final eps = _eps;
    final idx = _matchEpisodeIndex(eps, remarks);
    if (!mounted) return;
    setState(() {
      _flagIdx = i;
      _epIdx = idx;
      _epPage = idx >= 0 ? idx ~/ _epSize : 0;
      _status = '已切换线路: ${d.flags[i].show}';
    });
    if (autoPlay && idx >= 0) unawaited(_playAt(idx));
  }

  AspectSpec _aspectFromScale(String scale) {
    switch (scale) {
      case 'fill':
        return const AspectSpec(key: 'fill', fit: BoxFit.fill);
      case 'zoom':
        return const AspectSpec(key: 'zoom', fit: BoxFit.cover);
      case '16:9':
        return const AspectSpec(key: '16:9', fit: BoxFit.fill, ratio: 16 / 9);
      case '4:3':
        return const AspectSpec(key: '4:3', fit: BoxFit.fill, ratio: 4 / 3);
      default:
        return const AspectSpec(key: 'default', fit: BoxFit.contain);
    }
  }

  Future<void> _applyStableVolume(KotvPlayback p, bool on) async {
    await p.setStableVolume(on);
  }

  Future<void> _loadDanmakuForEpisode({
    required String playDanmaku,
    required String name,
    required String episode,
  }) async {
    _danmakuItems.value = const [];
    final engineBase = ref.read(apiProvider).baseUrl;
    final src = kotvRewriteEngineLocalUrl(playDanmaku.trim(), engineBase);
    if (src.isEmpty && _danmakuApi.trim().isEmpty) return;
    try {
      List<DanmakuItem> items = const [];
      if (src.isNotEmpty) {
        items = await DanmakuLoader.loadUrl(src);
      }
      if (items.isEmpty && _danmakuApi.trim().isNotEmpty) {
        items = await DanmakuLoader.loadApi(_danmakuApi, name: name, episode: episode);
      }
      if (!mounted) return;
      _danmakuItems.value = items;
    } catch (_) {
      if (mounted) _danmakuItems.value = const [];
    }
  }

  Future<void> _playAt(int epIdx, {bool fullscreen = false}) async {
    final d = _detail;
    if (d == null || d.flags.isEmpty) return;
    final flag = d.flags[_flagIdx.clamp(0, d.flags.length - 1)];
    final eps = _eps;
    if (epIdx < 0 || epIdx >= eps.length) return;
    final ep = eps[epIdx];
    _stoppedHard = false;
    // 换集：抬世代，关掉 READY/连播（BUFFERING 时 Clock=null）
    final gen = ++_playGen;
    final serial = ++_playAtSerial;
    _playbackLive = false;
    _sessionStartedAt = null;
    _boundMpvTextureId = null;
    _lastVideoW = 0;
    _lastVideoH = 0;
    _openingSeekDone = false;
    _endedSub?.cancel();
    _endedSub = null;
    _posSub?.cancel();
    _posSub = null;
    final epLooksMagnet = RegExp(r'^(magnet|thunder|ed2k):', caseSensitive: false).hasMatch(ep.url.trim()) ||
        ep.url.toLowerCase().contains('.torrent') ||
        ep.url.contains('/proxy/bt/') ||
        ep.url.toLowerCase().startsWith('magnet://local');
    // 立刻高亮：不要等停播/解析，否则 PC 要点 1–2 秒按钮才变色。
    if (mounted) {
      setState(() {
        _epIdx = epIdx;
        _epPage = epIdx ~/ _epSize;
        _magnetPlay = epLooksMagnet;
        // 全屏换集先盖黑：Surface stop/load 镂空时勿透出详情。
        if (_immersiveFullscreen) _immersiveEpCover = true;
        _status = epLooksMagnet
            ? '磁力解析中…'
            : (_epLooksDirectPlayUrl(ep.url) ? '换集中…' : '解析中…');
      });
    }
    _syncFullscreen();
    // 解析/拉流可能要数秒：先停播，避免上一集在后台继续出声。
    await _stopAllBackends();
    if (serial != _playAtSerial || !mounted) return;
    // 先 await 软取消上一集，再 play。unawaited 会与本次 play 竞态：
    // SoftCancel 抬 epoch → JS/JAR 立刻报「脚本调用已中断」。
    await ref.read(apiProvider).cancelPending(
          hard: false,
          thunder: _magnetPlay || epLooksMagnet,
        );
    if (serial != _playAtSerial || !mounted) return;
    if (mounted) {
      setState(() {
        _magnetPlay = epLooksMagnet;
      });
    }
    _syncAndroidAutoPip();
    _syncFullscreen();
    if (epLooksMagnet) _startBtProgressPoll();
    try {
      Map<String, dynamic> data;
      try {
        data = await ref.read(apiProvider).play(
              url: ep.url,
              site: d.site.isNotEmpty ? d.site : widget.site,
              id: widget.id,
              flag: flag.flag,
            );
      } catch (e) {
        // 从后台回来常见引擎僵死：Connection closed / refused。先拉起再重试一次。
        if (!_isLocalEngineConnError(e)) rethrow;
        final ok = await ref.read(engineLauncherProvider).recoverIfNeeded();
        if (!ok || serial != _playAtSerial || !mounted) rethrow;
        data = await ref.read(apiProvider).play(
              url: ep.url,
              site: d.site.isNotEmpty ? d.site : widget.site,
              id: widget.id,
              flag: flag.flag,
            );
      }
      if (serial != _playAtSerial || !mounted) return;
      final playUrl = kotvRewriteEngineLocalUrl(
        '${data['url'] ?? ''}',
        ref.read(apiProvider).baseUrl,
      );
      if (playUrl.isEmpty) throw Exception('空播放地址');
      final mediaUrl = kotvRewriteEngineLocalUrl(
        '${data['media'] ?? ''}',
        ref.read(apiProvider).baseUrl,
      );
      final headers = <String, String>{
        for (final e in Map<String, dynamic>.from((data['headers'] as Map?) ?? const {}).entries)
          if ('${e.key}'.trim().isNotEmpty && '${e.value}'.trim().isNotEmpty) '${e.key}': '${e.value}',
      };
      final magnet = data['magnet'] == true || playUrl.contains('/proxy/bt/') || epLooksMagnet;
      _magnetPlay = magnet;
      final drmRaw = data['drm'];
      final drm = drmRaw is Map
          ? Map<String, dynamic>.from(drmRaw)
          : null;
      final hasDrm = drm != null && '${drm['type'] ?? ''}'.trim().isNotEmpty;
      await LocalHistory.push(VodItem(
        id: d.id.isNotEmpty ? d.id : widget.id,
        name: d.name,
        pic: d.pic,
        site: d.site,
        remarks: ep.name,
      ));
      // 起播再读一次：设置页改播放器/软硬解/自动切换后，详情页可能还开着。
      var backendProxyPlay = data['backendProxyPlay'] == true;
      try {
        final st = await ref.read(apiProvider).getSettings();
        final settings = Map<String, dynamic>.from((st['settings'] as Map?) ?? const {});
        final fo = '${settings['playerFailover'] ?? ''}'.trim();
        if (fo.isNotEmpty) {
          _prefPlayerFailover = KotvPlaybackFailover.enabledFromSetting(fo) ? 'auto' : 'off';
        }
        final pv = '${settings['player'] ?? ''}'.trim();
        if (pv.isNotEmpty) {
          _prefPlayerVal = kotvClampPlayerVal(pv, live: false);
        }
        final decode = '${settings['playerDecode'] ?? ''}'.trim();
        if (decode.isNotEmpty) {
          _prefDecodeMode = decode;
        }
        final bp = '${settings['backendProxyPlay'] ?? ''}'.trim().toLowerCase();
        if (bp.isNotEmpty) {
          backendProxyPlay = bp == 'true' || bp == '1' || bp == 'on';
        }
      } catch (_) {}
      final remoteEngine = !kotvIsLocalEngineBaseUrl(ref.read(apiProvider).baseUrl);
      // 本机走本地代理；远端看开关。优先用引擎 play 接口算好的 preferSpiderProxy。
      final preferSpiderProxy = data.containsKey('preferSpiderProxy')
          ? data['preferSpiderProxy'] == true
          : (!remoteEngine || backendProxyPlay);
      // 有 DRM 强制 Exo（MPV/FVP 不解 Widevine）
      final startPlayer = (hasDrm && kotvIsAndroid())
          ? 'innie#exo'
          : _prefPlayerVal;
      final failover = KotvPlaybackFailover(
        playerVal: startPlayer,
        decodeMode: _prefDecodeMode,
        lockExoForDrm: hasDrm && kotvIsAndroid(),
        enabled: KotvPlaybackFailover.enabledFromSetting(_prefPlayerFailover),
      );
      Object? lastOpenError;
      var opened = false;
      for (var attempt = 0; attempt < 8; attempt++) {
        if (serial != _playAtSerial || !mounted) return;
        failover.markAttempt();
        _playerVal = failover.playerVal;
        _decodeMode = failover.decodeMode;
        await _stopInactiveBackends(_backend);
        if (serial != _playAtSerial || !mounted) return;
        final pb = _playback;
        await pb.setDecodeMode(failover.decodeMode);
        await pb.setRenderMode(_renderMode);
        // 本机/远端开加速：走 playUrl（/proxy）；远端默认才直连 CDN。
        final localMedia = mediaUrl.startsWith('file:') ||
            mediaUrl.startsWith('content:') ||
            (mediaUrl.startsWith('/') && !mediaUrl.contains('://'));
        late final String openUrl;
        late final Map<String, String>? openHeaders;
        if (!magnet && localMedia) {
          openUrl = mediaUrl;
          openHeaders = null;
        } else {
          final preferDirect = !hasDrm && !preferSpiderProxy;
          final resolved = kotvResolvePlayOpenTarget(
            playUrl: playUrl,
            mediaUrl: mediaUrl,
            headers: headers,
            magnet: magnet,
            preferDirectMedia: preferDirect,
          );
          openUrl = resolved.url;
          openHeaders = resolved.headers;
        }
        // 先挂播放器视图再 open（Texture / 平台视图需进树；全屏靠原位 Positioned）。
        setState(() {
          _playUrl = playUrl;
          _playerVal = failover.playerVal;
          _decodeMode = failover.decodeMode;
          _status = magnet ? '磁力缓冲中…' : '$_enginePrefix 加载中…';
        });
        _syncAndroidAutoPip();
        _syncFullscreen();
        await WidgetsBinding.instance.endOfFrame;
        if (serial != _playAtSerial || !mounted) return;
        _wirePlaybackNotify(pb);
        try {
          // 起播前定音量/倍速，避免先以默认 100 出声再被偏好压小。
          final speed = _prefSpeed;
          if (speed != null && speed > 0) {
            try {
              await pb.setRate(speed);
            } catch (_) {}
          }
          final vol = _prefVolume;
          if (vol != null) {
            try {
              await pb.setVolume(vol.clamp(0, 100));
            } catch (_) {}
          }
          // 起播缓冲由守卫无限等待；仅黑屏/视源失败抛 SilentVideo 才 failover。
          // 勿再套墙钟 timeout：慢源会被误切播放器。
          await pb.open(openUrl, headers: openHeaders, drm: hasDrm ? drm : null);
          try {
            await _playback.play();
          } catch (_) {}
          opened = true;
          break;
        } on KotvSilentVideoException catch (e) {
          lastOpenError = e;
          if (!failover.enabled) {
            // 关闭自动切换：不换引擎、不判失败，继续当前播放器。
            opened = true;
            break;
          }
        }
        final step = failover.nextStep();
        if (step == null) break;
        if (!mounted || serial != _playAtSerial) return;
        setState(() {
          _playerVal = step.playerVal;
          _decodeMode = step.decodeMode;
          _status = step.status;
        });
        _syncFullscreen();
        try {
          await pb.stop();
        } catch (_) {}
      }
      if (!opened) {
        throw lastOpenError ?? const KotvSilentVideoException();
      }
      if (serial != _playAtSerial || !mounted) return;
      // 音量/倍速已在 open 前套好；稳定音量用轻量 dynaudnorm，起播后立刻挂，勿再拖 800ms。
      if (_stableVolumeOn) {
        try {
          await _applyStableVolume(_playback, true);
        } catch (_) {}
      }
      if (!mounted) return;
      unawaited(_loadDanmakuForEpisode(
        playDanmaku: '${data['danmaku'] ?? ''}',
        name: d.name,
        episode: ep.name,
      ));
      // 仍未 READY：等进度回调 _markPlaybackLiveIfNeeded（STATE_READY 才挂 Clock）
      _playbackLive = false;
      _sessionStartedAt = DateTime.now();
      _openingSeekDone = false;
      if (gen == _playGen) {
        _wireEnded(_playback);
        _wirePosition(_playback);
        _wirePlaybackNotify(_playback);
      }
      _stopBtProgressPoll();
      _syncPlayStatus();
      ref.read(remoteBridgeProvider)?.reportMedia(state: 'playing', title: '${d.name} · ${ep.name}', url: playUrl);
      if (fullscreen && mounted) {
        await _enterFullscreen();
      }
    } catch (e) {
      if (serial != _playAtSerial) return;
      _stopBtProgressPoll();
      _playbackLive = false;
      _sessionStartedAt = null;
      setState(() {
        _playUrl = '';
        _immersiveEpCover = false;
        _status = _friendlyPlayError(
          e,
          triedSwitch: KotvPlaybackFailover.enabledFromSetting(_prefPlayerFailover),
        );
      });
      _syncAndroidAutoPip();
      _syncFullscreen();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _friendlyPlayError(
                e,
                triedSwitch: KotvPlaybackFailover.enabledFromSetting(_prefPlayerFailover),
              ),
            ),
          ),
        );
      }
    }
  }

  /// 以下常见直链这类换集不显示「解析」浮层。
  bool _epLooksDirectPlayUrl(String raw) {
    final u = raw.trim().toLowerCase();
    if (u.isEmpty) return false;
    if (u.startsWith('rtmp:')) return true;
    if (!(u.startsWith('http://') || u.startsWith('https://'))) return false;
    if (u.contains('url=http') || u.contains('v=http') || u.contains('.html')) return false;
    const marks = ['.m3u8', '.mp4', '.mkv', '.flv', '.mpd', '.mp3', '.m4a', '.aac', 'video/tos'];
    for (final m in marks) {
      if (u.contains(m)) return true;
    }
    return false;
  }

  /// 折叠「播放失败: 解析失败: 解析失败: …」这类层层包装。
  String _friendlyPlayError(Object e, {bool triedSwitch = true}) {
    if (e is KotvSilentVideoException) {
      final m = e.message.trim();
      if (m.contains('视频源')) {
        return triedSwitch ? '播放失败: 无可用视频源（已尝试修复并切换播放器）' : '播放失败: 无可用视频源';
      }
      if (m.contains('进度停滞')) {
        return triedSwitch ? '播放失败: 播放中进度停滞（已尝试切换播放器）' : '播放失败: 播放中进度停滞';
      }
      return triedSwitch ? '播放失败: 无画面（已尝试可用播放器）' : '播放失败: 无画面';
    }
    var s = '$e';
    s = s.replaceFirst(RegExp(r'^(Exception|KotvApiException):\s*'), '');
    while (s.contains('解析失败: 解析失败:')) {
      s = s.replaceAll('解析失败: 解析失败:', '解析失败:');
    }
    while (s.contains('播放失败: 播放失败:')) {
      s = s.replaceAll('播放失败: 播放失败:', '播放失败:');
    }
    if (s.startsWith('播放失败:')) return s;
    if (s.startsWith('解析失败:')) return '播放失败: ${s.substring('解析失败:'.length).trimLeft()}';
    return '播放失败: $s';
  }

  bool _isLocalEngineConnError(Object e) {
    final s = '$e';
    return s.contains('Connection closed') ||
        s.contains('Connection refused') ||
        s.contains('SocketException') ||
        s.contains('ClientException') ||
        s.contains('Failed host lookup') ||
        s.contains('TimeoutException') ||
        s.contains('Broken pipe');
  }

  /// 全屏/详情共用画面。原位全屏时 Element 不挪树；Android 原生 Surface 另加 KeyedSubtree。
  /// 固定画幅：Exo/其它用 [AspectRatio]；Android MPV 走原生 video-aspect-override，勿再套一层。
  Widget _buildSharedVideo({BoxFit fit = BoxFit.contain}) {
    Widget inner = kotvPlaybackView(
      playerVal: _playerVal,
      playback: _playback,
      mpv: _mk,
      fit: fit,
    );
    // 仅 Android 原生 MPV Surface 需要跨布局保活同一 PlatformView。
    if (kotvIsAndroid() && _mk is NativeMpvPlayback) {
      inner = KeyedSubtree(key: _videoHostKey, child: inner);
    }
    final ratio = _aspect.ratio;
    final mpvNativeScale = kotvIsAndroid() && _mk is NativeMpvPlayback;
    if (!mpvNativeScale && ratio != null && ratio > 0) {
      inner = ColoredBox(
        color: Colors.black,
        child: Center(
          child: AspectRatio(aspectRatio: ratio, child: inner),
        ),
      );
    }
    if (_backend == KotvEmbedBackend.mpv && kotvIsAndroid() && _mk is NativeMpvPlayback) {
      final m = _mk! as NativeMpvPlayback;
      return ValueListenableBuilder<int>(
        valueListenable: m.surfaceRev,
        builder: (context, _, __) => inner,
      );
    }
    return inner;
  }

  /// 全平台：Texture/PlatformView 留在同一 Positioned 宿主，全屏只改几何。
  bool get _useStableVideoLayer => !_miniDesktop;

  void _scheduleSyncVideoSlot() {
    if (_videoSlotSyncScheduled || !_useStableVideoLayer) return;
    _videoSlotSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _videoSlotSyncScheduled = false;
      _syncVideoSlotRect();
    });
  }
  /// 非全屏：黑槽尺寸（LayerLink 管位置）+ 内容区裁剪矩形（防盖顶栏）。
  void _syncVideoSlotRect() {
    if (!mounted || !_useStableVideoLayer || _immersiveFullscreen) return;
    final slotBox = _videoSlotKey.currentContext?.findRenderObject() as RenderBox?;
    final bodyBox = _bodyClipKey.currentContext?.findRenderObject() as RenderBox?;
    final stackBox = _detailStackKey.currentContext?.findRenderObject() as RenderBox?;

    Size? nextSlot;
    if (slotBox != null && slotBox.hasSize) {
      final s = slotBox.size;
      if (s.width >= 1 && s.height >= 1) nextSlot = s;
    }

    Rect? nextClip;
    if (bodyBox != null && stackBox != null && bodyBox.hasSize && stackBox.hasSize) {
      final o = bodyBox.localToGlobal(Offset.zero, ancestor: stackBox);
      final r = o & bodyBox.size;
      if (r.width >= 1 && r.height >= 1) nextClip = r;
    }

    final prevSlot = _videoLayerRect;
    final prevClip = _bodyClipRect;
    final slotSame = nextSlot == null ||
        (prevSlot != null &&
            (prevSlot.width - nextSlot.width).abs() < 0.5 &&
            (prevSlot.height - nextSlot.height).abs() < 0.5);
    final clipSame = nextClip == null ||
        (prevClip != null &&
            (prevClip.left - nextClip.left).abs() < 0.5 &&
            (prevClip.top - nextClip.top).abs() < 0.5 &&
            (prevClip.width - nextClip.width).abs() < 0.5 &&
            (prevClip.height - nextClip.height).abs() < 0.5);
    if (slotSame && clipSame) return;
    setState(() {
      if (nextSlot != null) _videoLayerRect = Offset.zero & nextSlot;
      if (nextClip != null) _bodyClipRect = nextClip;
    });
  }
  /// 黑槽占位：[CompositedTransformTarget] 供画面层跟随；LayoutBuilder 捕获
  /// 不经 rebuild 的布局变化（窗口缩放、顶栏高度变化）刷新尺寸。
  Widget _buildVideoSlot() {
    return CompositedTransformTarget(
      link: _videoLink,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          final prev = _videoLayerRect;
          if (!_immersiveFullscreen &&
              size.width >= 1 &&
              size.height >= 1 &&
              (prev == null ||
                  (prev.width - size.width).abs() >= 0.5 ||
                  (prev.height - size.height).abs() >= 0.5)) {
            _scheduleSyncVideoSlot();
          }
          return ColoredBox(key: _videoSlotKey, color: Colors.black);
        },
      ),
    );
  }
  /// [stackSize]：详情 Stack 实测约束。沉浸全屏勿用 MediaQuery 整窗尺寸——
  /// 若底栏/SafeArea 仍占位，整窗高会比可见区大，contain 居中会明显偏下。
  Rect _stableVideoRect(BuildContext context, {Size? stackSize}) {
    if (_immersiveFullscreen) {
      final s = stackSize;
      if (s != null && s.width >= 1 && s.height >= 1) {
        return Offset.zero & s;
      }
      return _videoLayerRect ?? (Offset.zero & MediaQuery.sizeOf(context));
    }
    return _videoLayerRect ?? Rect.zero;
  }
  Widget _buildStableVideoLayer(BuildContext context, {Size? stackSize}) {
    final rect = _stableVideoRect(context, stackSize: stackSize);
    if (rect.width < 1 || rect.height < 1) return const SizedBox.shrink();
    return ValueListenableBuilder<double>(
      valueListenable: _fsSwipeDy,
      builder: (context, swipeDy, child) {
        if (_immersiveFullscreen) {
          return Positioned(
            left: rect.left,
            top: rect.top + swipeDy,
            width: rect.width,
            height: rect.height,
            child: child!,
          );
        }
        // 非全屏：Follower 跟黑槽；外层裁到 Expanded（顶栏下），下滑不会盖住顶栏。
        final clip = _bodyClipRect;
        if (clip == null || clip.width < 1 || clip.height < 1) {
          return const SizedBox.shrink();
        }
        return Positioned(
          left: clip.left,
          top: clip.top,
          width: clip.width,
          height: clip.height,
          child: ClipRect(
            child: Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                CompositedTransformFollower(
                  link: _videoLink,
                  showWhenUnlinked: false,
                  child: SizedBox(
                    width: rect.width,
                    height: rect.height,
                    child: child,
                  ),
                ),
              ],
            ),
          ),
        );
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (_playUrl.isEmpty || _immersiveFullscreen) return;
          // 换集/解析中勿 toggle：布局抖动时 pointer-up 易落到画面上，造成隔集暂停。
          if (_status.contains('换集中') ||
              _status.contains('解析') ||
              _status.contains('嗅探') ||
              _status.contains('加载中')) {
            return;
          }
          unawaited(_playback.playOrPause());
          setState(() {});
        },
        onSecondaryTap: _immersiveFullscreen ? null : () => kotvHandleAppBack?.call(),
        onDoubleTap: _immersiveFullscreen
            ? null
            : () {
                if (_playUrl.isNotEmpty) {
                  unawaited(_enterFullscreen());
                } else if (_eps.isNotEmpty) {
                  unawaited(_playAt(_epIdx >= 0 ? _epIdx : 0, fullscreen: true));
                }
              },
        child: Stack(
          fit: StackFit.expand,
          children: [
            ExcludeFocus(child: _buildSharedVideo(fit: _aspect.fit)),
            // 解析/无帧/缓冲：黑底盖住 PlatformView。加载阶段滑动时 Hybrid Composition
            // 易把 Flutter 控件与 Surface 叠成双影（Exo/MPV 都有），与是否 MediaOverlay 无关。
            ListenableBuilder(
              listenable: _playback,
              builder: (context, _) {
                final parsing = _status.contains('解析') ||
                    _status.contains('嗅探') ||
                    _status.contains('换集中');
                final noFrame = _playback.width <= 0 && _playback.height <= 0;
                final cover = parsing || noFrame || _playback.stalling;
                if (!cover) return const SizedBox.shrink();
                return const ColoredBox(color: Colors.black);
              },
            ),
            if (_immersiveFullscreen) ...[
              // 全屏控件在外层；此处不叠内嵌解析/中心钮。
            ] else ...[
              ValueListenableBuilder<List<DanmakuItem>>(
                valueListenable: _danmakuItems,
                builder: (context, items, _) => DanmakuOverlay(
                  enabled: _danmakuOn,
                  position: _playback.position,
                  items: items,
                  fontSize: _danmakuSize,
                  opacity: _danmakuOpacity,
                  rows: _danmakuRows,
                ),
              ),
              KotvBufferingOverlay(
                player: _playback,
                force: _status.contains('解析') ||
                    _status.contains('嗅探') ||
                    _status.contains('换集中'),
                forceText: (_status.contains('解析') ||
                        _status.contains('嗅探') ||
                        _status.contains('换集中'))
                    ? '正在解析播放地址'
                    : null,
              ),
              ExcludeFocus(
                child: CenterPlayPauseButton(
                  player: _playback,
                  hideWhenBuffering: true,
                  enabled: !_status.contains('解析') &&
                      !_status.contains('嗅探') &&
                      !_status.contains('换集中'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 全屏控件跟详情 setState；勿再用 ValueNotifier 整页重建（GlobalKey 易卸树成环）。
  void _syncFullscreen() {
    if (!mounted || !_immersiveFullscreen) return;
    setState(() {});
  }

  Widget _buildImmersiveFullscreenPage({bool externalVideo = false}) {
    final d = _detail!;
    final api = ref.read(apiProvider);
    final id = d.id.isNotEmpty ? d.id : widget.id;
    final site = d.site.isNotEmpty ? d.site : widget.site;
    final eps = _eps;
    final epIdx = _epIdx;
    final title = '${d.name}${epIdx >= 0 && epIdx < eps.length ? ' · ${eps[epIdx].name}' : ''}';
    return ValueListenableBuilder<List<DanmakuItem>>(
      valueListenable: _danmakuItems,
      builder: (context, danmakuItems, _) => DetailFullscreenPage(
        key: _fsPageKey,
        embedded: true,
        externalVideo: externalVideo,
        swipeOffset: _fsSwipeDy,
        videoChild: externalVideo
            ? const SizedBox.shrink()
            : _buildSharedVideo(fit: _aspect.fit),
        playback: _playback,
        vodName: d.name,
        title: title,
        episodes: eps.map((e) => e.name).toList(),
        epIdx: epIdx,
        playUrl: _playUrl,
        decodeMode: _decodeMode,
        renderMode: _renderMode,
        aspect: _aspect,
        onAspectChanged: (a) {
          setState(() => _aspect = a);
          unawaited(_playback.setVideoScale(a.key));
        },
        danmakuOn: _danmakuOn,
        danmakuItems: danmakuItems,
        danmakuSize: _danmakuSize,
        danmakuOpacity: _danmakuOpacity,
        danmakuRows: _danmakuRows,
        ambientOn: _ambientOn,
        stableVolumeOn: _stableVolumeOn,
        keepLabel: _kept ? '取消收藏' : '收藏',
        offsetId: id,
        offsetSite: site,
        openingSec: _openingSec,
        endingSec: _endingSec,
        desktopFullscreen: _desktopFs,
        onExitEmbedded: () => unawaited(_exitImmersiveFullscreen()),
        onOffsetsChanged: (open, end) {
          if (!mounted) return;
          setState(() {
            _openingSec = open;
            _endingSec = end;
          });
        },
        onSelectEp: (i) => _playAt(i),
        onNext: () => _playAt(_epIdx + 1),
        onPrev: () => _playAt(_epIdx - 1),
        onDecodeChanged: (mode) {
          if (mounted) {
            setState(() {
              _decodeMode = mode;
              _prefDecodeMode = mode;
            });
          }
        },
        onRenderChanged: (mode) {
          // 须在 persist/setSetting 完成前重建画面，否则 Texture↔Surface 会音画分离定格。
          if (mounted) {
            setState(() => _renderMode = kotvNormalizePlayerRender(mode));
          }
        },
        onPersistSetting: (k, v) async {
          await api.setSetting(k, v);
          if (!mounted) return;
          if (k == 'playerScale') {
            setState(() => _aspect = _aspectFromScale(v));
            unawaited(_playback.setVideoScale(v));
          }
          if (k == 'playerAmbient') {
            setState(() => _ambientOn = v.toLowerCase() == 'true');
          }
          if (k == 'playerStableVolume') {
            final on = v.toLowerCase() == 'true';
            setState(() => _stableVolumeOn = on);
            unawaited(_applyStableVolume(_playback, on));
          }
          if (k == 'danmaku') {
            setState(() => _danmakuOn = v.toLowerCase() == 'true');
          }
          if (k == 'danmakuApi') {
            setState(() => _danmakuApi = v);
            if (_detail != null && _eps.isNotEmpty && _epIdx >= 0 && _epIdx < _eps.length) {
              unawaited(_loadDanmakuForEpisode(
                playDanmaku: '',
                name: _detail!.name,
                episode: _eps[_epIdx].name,
              ));
            }
          }
          if (k == 'danmakuSize') {
            setState(() => _danmakuSize = double.tryParse(v) ?? _danmakuSize);
          }
          if (k == 'danmakuOpacity') {
            final op = double.tryParse(v);
            if (op != null) {
              setState(() => _danmakuOpacity = (op > 1 ? op / 100.0 : op).clamp(0.15, 1.0));
            }
          }
          if (k == 'danmakuRows') {
            setState(() => _danmakuRows = int.tryParse(v) ?? _danmakuRows);
          }
          if (k == 'playerDecode') {
            final next = v.trim().isEmpty ? 'auto' : v.trim();
            setState(() {
              _decodeMode = next;
              _prefDecodeMode = next;
            });
          }
          if (k == 'playerRender') {
            final next = kotvNormalizePlayerRender(v);
            if (_renderMode != next) setState(() => _renderMode = next);
          }
          if (k == 'player') {
            final prev = _playerVal;
            final next = kotvClampPlayerVal(v, live: false);
            setState(() {
              _playerVal = next;
              _prefPlayerVal = next;
            });
            if (next != prev && _epIdx >= 0) {
              unawaited(_playAt(_epIdx));
            }
          }
        },
        onPlayerStatus: api.playerStatus,
        onExternalPlayer: (player) => api.playerExternal(url: _playUrl, player: player),
        onToggleKeep: () async {
          final item = VodItem(id: id, name: d.name, pic: d.pic, site: site, remarks: d.remarks);
          final kept = await LocalCollect.toggle(item);
          if (mounted) {
            setState(() => _kept = kept);
          }
          return kept ? '取消收藏' : '收藏';
        },
        onDanmakuChanged: (v) {
          if (mounted) setState(() => _danmakuOn = v);
        },
        onAmbientChanged: (v) {
          if (mounted) setState(() => _ambientOn = v);
        },
        onParse: () => unawaited(_pickParse()),
        onRefresh: () {
          if (_epIdx >= 0) unawaited(_playAt(_epIdx));
        },
        onCast: () => unawaited(_cast()),
        onMini: () {
          unawaited(_exitImmersiveFullscreen().then((_) {
            if (mounted) unawaited(_enterMini());
          }));
        },
      ),
    );
  }

  Future<void> _enterFullscreen([KotvDesktopFullscreenKind desktopFs = KotvDesktopFullscreenKind.window]) async {
    final d = _detail;
    if (d == null || !mounted || _playUrl.isEmpty) return;
    if (_miniDesktop) await _exitMini();
    if (!mounted) return;
    if (!kotvIsDesktop() && !kIsWeb) {
      // 抖音式：全屏保持竖屏，上下滑切集；点「全屏观看」才锁横屏。
      try {
        await kotvLockPortrait();
      } catch (_) {}
    }
    // 先藏系统栏：锁竖屏后系统 UI 可能被 OS 拉回，后面再补一次。
    await kotvEnterSystemFullscreen(desktopFs);
    if (!mounted) return;
    ref.read(detailImmersiveFullscreenProvider.notifier).state = true;
    final full = MediaQuery.sizeOf(context);
    setState(() {
      _desktopFs = desktopFs;
      _immersiveFullscreen = true;
      _fsSwipeDy.value = 0;
      // 立刻铺满，避免先卸树再重建；外层 Positioned 只改几何。
      if (_useStableVideoLayer) {
        _videoLayerRect = Offset.zero & full;
      }
    });
    _syncFullscreen();
    // 壳层 SafeArea/底栏撤掉后再补一次沉浸，避免状态栏占位。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_immersiveFullscreen) return;
      unawaited(kotvEnterSystemFullscreen(_desktopFs));
    });
  }

  Future<void> _exitImmersiveFullscreen() async {
    if (!_immersiveFullscreen) return;
    // 先挡二次返回：Focus 与 PopScope/壳层常在同一按键上各走一遍。
    _suppressDetailPopUntil = DateTime.now().add(const Duration(milliseconds: 800));
    _fsSwipeDy.value = 0;
    final wasDisplay = _desktopFs == KotvDesktopFullscreenKind.display;
    ref.read(detailImmersiveFullscreenProvider.notifier).state = false;
    if (mounted) {
      setState(() {
        _immersiveFullscreen = false;
        _immersiveEpCover = false;
      });
      // 黑槽需重新进树后量测：同帧可能仍为空，再排一次。
      _syncVideoSlotRect();
      _scheduleSyncVideoSlot();
    }
    await kotvExitSystemFullscreen(wasDisplayFullscreen: wasDisplay);
    if (!kotvIsDesktop()) {
      try {
        await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      } catch (_) {}
    }
  }

  Future<void> _cast() async {
    if (_playUrl.isEmpty) {
      if (mounted) showAppNews(context, '请先播放内容再投屏');
      return;
    }
    final msg = await runKotvCast(
      context,
      ref.read(apiProvider),
      onStatus: (m) {
        if (mounted) setState(() => _status = m);
      },
    );
    if (msg != null && mounted) setState(() => _status = msg);
  }

  Future<void> _enterMini() async {
    if (_playUrl.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请先播放内容')));
      }
      return;
    }
    if (kIsWeb) {
      _playback.onPictureInPictureChanged = (inPip) {
        if (!mounted) return;
        setState(() => _miniDesktop = inPip);
      };
      final ok = await _playback.enterPictureInPicture();
      if (!mounted) return;
      if (ok) {
        setState(() => _miniDesktop = true);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法进入画中画，请检查浏览器是否支持')),
        );
      }
      return;
    }
    if (!MiniPlayerWindow.supported) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('当前平台不支持迷你桌面播放')));
      }
      return;
    }
    MiniPlayerWindow.onAndroidPipChanged = (inPip) {
      if (!mounted) return;
      setState(() => _miniDesktop = inPip);
    };
    await MiniPlayerWindow.enter();
    if (!mounted) return;
    if (MiniPlayerWindow.active) {
      setState(() => _miniDesktop = true);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('无法进入小窗，请检查系统是否支持画中画')));
    }
  }

  Future<void> _exitMini() async {
    if (kIsWeb) {
      await _playback.exitPictureInPicture();
      if (!mounted) return;
      setState(() => _miniDesktop = false);
      return;
    }
    await MiniPlayerWindow.exit();
    if (!mounted) return;
    setState(() => _miniDesktop = false);
  }

  Widget _videoStage({required bool interactive}) {
    final d = _detail;
    final stableSlot = _useStableVideoLayer && _playUrl.isNotEmpty;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: stableSlot
          ? null
          : () {
              if (_playUrl.isEmpty) return;
              if (_status.contains('换集中') ||
                  _status.contains('解析') ||
                  _status.contains('嗅探') ||
                  _status.contains('加载中')) {
                return;
              }
              unawaited(_playback.playOrPause());
              setState(() {});
            },
      onSecondaryTap: () => kotvHandleAppBack?.call(),
      onDoubleTap: interactive && !stableSlot
          ? () {
              if (_playUrl.isNotEmpty) {
                unawaited(_enterFullscreen());
              } else if (_eps.isNotEmpty) {
                unawaited(_playAt(_epIdx >= 0 ? _epIdx : 0, fullscreen: true));
              }
            }
          : null,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_playUrl.isEmpty)
            (d == null || d.pic.isEmpty
                ? const ColoredBox(
                    color: Color(0xFF2A1848),
                    child: Center(
                      child: Text('选择剧集开始播放', style: TextStyle(color: Colors.white70, fontSize: 16)),
                    ),
                  )
                : KotvNetworkImage(
                    d.pic,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const ColoredBox(
                      color: Color(0xFF2A1848),
                      child: Center(
                        child: Text('封面加载失败', style: TextStyle(color: Colors.white54, fontSize: 14)),
                      ),
                    ),
                  ))
          else if (stableSlot)
            // 桌面：仅占位 + LayerLink 目标；真正 Texture 在 [_buildStableVideoLayer]。
            _buildVideoSlot()
          else
            // 勿包 ListenableBuilder：position/playing 高频 notify 会重建 Video。
            ExcludeFocus(
              child: _buildSharedVideo(fit: _aspect.fit),
            ),
          if (_playUrl.isNotEmpty && !stableSlot)
            KotvBufferingOverlay(
              player: _playback,
              force: _status.contains('解析') ||
                  _status.contains('嗅探') ||
                  _status.contains('换集中'),
              forceText: (_status.contains('解析') ||
                      _status.contains('嗅探') ||
                      _status.contains('换集中'))
                  ? '正在解析播放地址'
                  : null,
            ),
          if (_playUrl.isNotEmpty && !stableSlot)
            // 中心播停留给触控；遥控器走底栏 TvFocus，避免焦点停在画面正中出不去。
            ExcludeFocus(
              child: CenterPlayPauseButton(
                player: _playback,
                hideWhenBuffering: true,
                enabled: !_status.contains('解析') &&
                    !_status.contains('嗅探') &&
                    !_status.contains('换集中'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _inlineChrome() {
    return VodInlineControls(
      player: _playback,
      miniActive: _miniDesktop,
      autofocusPlay: _chromeRemoteFocus,
      onCast: () => unawaited(_cast()),
      onMini: () => unawaited(_miniDesktop ? _exitMini() : _enterMini()),
      onExpand: (kind) => unawaited(_enterFullscreen(kind)),
      onStop: () async {
        await _stopHard();
        if (_miniDesktop) await _exitMini();
        if (mounted) {
          setState(() {
            _status = '已停止';
          });
        }
      },
    );
  }

  KeyEventResult _onInlinePlayerKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || _playUrl.isEmpty) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (kotvIsMenuKey(key)) {
      setState(() => _chromeRemoteFocus = true);
      return KeyEventResult.handled;
    }
    // 底栏已获焦：左右调进度，上下留给 TvFocus。
    if (_chromeRemoteFocus && (kotvIsLeftKey(key) || kotvIsMediaRewind(key))) {
      final p = _playback.position - const Duration(seconds: 10);
      unawaited(_playback.seek(p.isNegative ? Duration.zero : p));
      return KeyEventResult.handled;
    }
    if (_chromeRemoteFocus && (kotvIsRightKey(key) || kotvIsMediaFastForward(key))) {
      unawaited(_playback.seek(_playback.position + const Duration(seconds: 10)));
      return KeyEventResult.handled;
    }
    // 起播后方向键也可把焦点落到底栏，避免只能靠菜单键。
    if (_playUrl.isNotEmpty &&
        !_chromeRemoteFocus &&
        (kotvIsUpKey(key) || kotvIsDownKey(key) || kotvIsLeftKey(key) || kotvIsRightKey(key))) {
      setState(() => _chromeRemoteFocus = true);
      return KeyEventResult.handled;
    }
    if (kotvIsEnterKey(key) || kotvIsMediaPlayPause(key)) {
      final primary = FocusManager.instance.primaryFocus;
      if (primary == null || primary == node) {
        unawaited(_playback.playOrPause());
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    // 上下：交给底栏 TvFocus / 剧集等全局遍历
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    if (_useStableVideoLayer && _playUrl.isNotEmpty && !_immersiveFullscreen) {
      _scheduleSyncVideoSlot();
    }

    final Widget body;
    if (_miniDesktop && _detail != null) {
      // 主界面已收起：仅桌面悬浮播放层；控件半透明，鼠标移入显示
      body = Scaffold(
        backgroundColor: Colors.transparent,
        body: DragToMoveArea(
          child: MiniHoverShell(
            player: _playback,
            video: _videoStage(interactive: true),
            chrome: VodInlineControls(
              player: _playback,
              miniActive: true,
              translucent: true,
              onCast: () => unawaited(_cast()),
              onMini: () => unawaited(_exitMini()),
              onExpand: (kind) => unawaited(_enterFullscreen(kind)),
              onStop: () async {
                await _stopHard();
                if (_miniDesktop) await _exitMini();
                if (mounted) {
                  setState(() {
                    _status = '已停止';
                  });
                }
              },
            ),
          ),
        ),
      );
    } else if (_useStableVideoLayer) {
      // 桌面：Scaffold 与全屏控件切换时，Texture 始终挂在同一 Positioned 上。
      final detailScaffold = Scaffold(
        backgroundColor: Colors.transparent,
        body: AppBackdrop(
          child: Column(
            children: [
              LibraryTopBar(
                onBack: () => unawaited(_leavePage()),
                onSearch: () => unawaited(_leavePage(afterPop: () => goKotvPage(ref, KotvPage.search))),
                onProfile: () => unawaited(_leavePage(afterPop: () => goKotvPage(ref, KotvPage.profile))),
                onNews: () => showAppNews(context, remoteHint(ref)),
                title: widget.title.isNotEmpty ? widget.title : '详情',
              ),
              Expanded(
                child: KeyedSubtree(
                  key: _bodyClipKey,
                  child: _loading
                      ? Center(child: CircularProgressIndicator(color: KotvPalette.of(context).primary))
                      : _error != null
                          ? Center(child: Text(_error!, style: TextStyle(color: KotvPalette.of(context).fg)))
                          : _detail == null
                              ? const SizedBox.shrink()
                              : _buildBody(),
                ),
              ),
            ],
          ),
        ),
      );
      body = LayoutBuilder(
        builder: (context, constraints) {
          final stackSize = constraints.biggest;
          // 沉浸中若壳层 provider 被误清，同帧自愈，避免底栏/SafeArea 吃掉高度。
          if (_immersiveFullscreen && !ref.read(detailImmersiveFullscreenProvider)) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted || !_immersiveFullscreen) return;
              ref.read(detailImmersiveFullscreenProvider.notifier).state = true;
            });
          }
          if (_immersiveFullscreen &&
              stackSize.width >= 1 &&
              stackSize.height >= 1 &&
              (_videoLayerRect == null ||
                  (_videoLayerRect!.width - stackSize.width).abs() >= 0.5 ||
                  (_videoLayerRect!.height - stackSize.height).abs() >= 0.5)) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted || !_immersiveFullscreen) return;
              setState(() => _videoLayerRect = Offset.zero & stackSize);
            });
          }
          return Stack(
            key: _detailStackKey,
            fit: StackFit.expand,
            children: [
              // Android Hybrid Surface：沉浸时卸详情树 + 黑底，避免镂空透出底层。
              // 桌面仍用 Offstage 保活（LayerLink / media_kit Texture 不宜整树卸装）。
              if (kotvIsAndroid()) ...[
                if (_immersiveFullscreen) const ColoredBox(color: Colors.black),
                if (!_immersiveFullscreen) detailScaffold,
              ] else
                Offstage(
                  offstage: _immersiveFullscreen,
                  child: TickerMode(
                    enabled: !_immersiveFullscreen,
                    child: detailScaffold,
                  ),
                ),
              // 叠在 Scaffold 上以便全屏不卸 Texture；非全屏由 [_bodyClipRect] 裁切，不盖顶栏。
              if (_playUrl.isNotEmpty) _buildStableVideoLayer(context, stackSize: stackSize),
              // 换集/解析：盖在画面上（Texture 路径有效；Surface 镂空时靠上面黑底 + 不挂详情）。
              if (_immersiveFullscreen && _immersiveEpCover)
                const Positioned.fill(
                  child: IgnorePointer(child: ColoredBox(color: Colors.black)),
                ),
              // 切集/换播放器时 playUrl 可能短暂变化：全屏页勿随 playUrl 卸树。
              if (_immersiveFullscreen && _detail != null)
                _buildImmersiveFullscreenPage(externalVideo: true),
            ],
          );
        },
      );
    } else if (_immersiveFullscreen && _detail != null) {
      body = _buildImmersiveFullscreenPage();
    } else {
      body = Scaffold(
        backgroundColor: Colors.transparent,
        body: AppBackdrop(
          child: Column(
            children: [
              LibraryTopBar(
                onBack: () => unawaited(_leavePage()),
                onSearch: () => unawaited(_leavePage(afterPop: () => goKotvPage(ref, KotvPage.search))),
                onProfile: () => unawaited(_leavePage(afterPop: () => goKotvPage(ref, KotvPage.profile))),
                onNews: () => showAppNews(context, remoteHint(ref)),
                title: widget.title.isNotEmpty ? widget.title : '详情',
              ),
              Expanded(
                child: _loading
                    ? Center(child: CircularProgressIndicator(color: KotvPalette.of(context).primary))
                    : _error != null
                        ? Center(child: Text(_error!, style: TextStyle(color: KotvPalette.of(context).fg)))
                        : _buildBody(),
              ),
            ],
          ),
        ),
      );
    }

    return PopScope(
      // 返回必须先 await 硬停，禁止 canPop 抢跑（所有播放器共用 _stopHard）。
      canPop: _allowPop,
      onPopInvoked: (didPop) {
        if (didPop) return;
        if (_immersiveFullscreen) {
          unawaited(_exitImmersiveFullscreen());
          return;
        }
        // 刚退全屏：同一次返回不要再出详情（对齐 PC：全屏返回只上一层）。
        final until = _suppressDetailPopUntil;
        if (until != null && DateTime.now().isBefore(until)) {
          return;
        }
        unawaited(_leavePage());
      },
      child: body,
    );
  }

  Widget _buildBody() {
    final d = _detail!;
    final flags = d.flags;
    final eps = _eps;
    final pageCount = eps.isEmpty ? 0 : ((eps.length - 1) ~/ _epSize) + 1;
    final pageEps = eps.skip(_epPage * _epSize).take(_epSize).toList();
    final director = d.director.isEmpty ? '暂无' : d.director;
    final actor = d.actor.isEmpty ? '暂无' : d.actor;
    final introRaw = d.content.isEmpty ? '' : d.content;
    final intro = introRaw
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final introText = intro.isEmpty ? '暂无' : intro;
    final compact = KotvLayout.isCompact(context);
    final p = KotvPalette.of(context);
    final fg = p.fg;
    final muted = p.muted;

    Widget videoPane({required bool expand}) {
      return Container(
        decoration: BoxDecoration(
          color: const Color(0xEE0A0A12),
          borderRadius: BorderRadius.circular(14),
        ),
        padding: const EdgeInsets.all(8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          // 画面 ExcludeFocus + 原生 PlatformView 关焦点；控件靠 TvFocus 参与全局遍历。
          child: expand
              ? Column(
                  children: [
                    Expanded(child: _videoStage(interactive: true)),
                    if (_playUrl.isNotEmpty) _inlineChrome(),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AspectRatio(aspectRatio: 16 / 9, child: _videoStage(interactive: true)),
                    if (_playUrl.isNotEmpty) _inlineChrome(),
                  ],
                ),
        ),
      );
    }

    Widget metaBlock() {
      final info = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '导演：$director',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: muted, fontSize: 15, height: 1.45),
          ),
          const SizedBox(height: 6),
          Text(
            '演员：$actor',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: muted, fontSize: 15, height: 1.45),
          ),
          const SizedBox(height: 6),
          Text(
            '简介：$introText',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: muted, fontSize: 15, height: 1.5),
          ),
        ],
      );
      return InkWell(
        onTap: () => _showVodMeta(d),
        borderRadius: BorderRadius.circular(8),
        child: Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: info),
      );
    }

    Widget actionRow() {
      final compactActions = compact || KotvLayout.useBottomNav(context);
      final rowH = compactActions ? 40.0 : 58.0;
      return SizedBox(
        height: rowH,
        child: HScroll(
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
            _action('全屏', Icons.crop_free_rounded, () {
              if (_playUrl.isNotEmpty) {
                unawaited(_enterFullscreen());
              } else if (_epIdx >= 0) {
                unawaited(_playAt(_epIdx, fullscreen: true));
              } else if (eps.isNotEmpty) {
                unawaited(_playAt(0, fullscreen: true));
              }
            }),
            _action('搜索', Icons.search_rounded, () {
              final q = _quickSearchQuery(d);
              unawaited(_leavePage(afterPop: () {
                ref.read(pendingSearchProvider.notifier).state = q;
                goKotvPage(ref, KotvPage.search);
              }));
            }),
            _action(_reversed ? '正序' : '倒叙', Icons.swap_vert_rounded, () {
              final n = _eps.length;
              final old = _epIdx;
              setState(() {
                _reversed = !_reversed;
                if (old >= 0 && n > 0) {
                  _epIdx = n - 1 - old;
                  _epPage = _epIdx ~/ _epSize;
                } else {
                  _epPage = 0;
                }
                _status = _reversed ? '已倒序' : '已正序';
              });
            }),
            _action(_kept ? '取消收藏' : '收藏', Icons.star_border_rounded, () async {
              final kept = await LocalCollect.toggle(VodItem(
                id: d.id.isNotEmpty ? d.id : widget.id,
                name: d.name,
                pic: d.pic,
                site: d.site.isNotEmpty ? d.site : widget.site,
                remarks: d.remarks,
              ));
              setState(() {
                _kept = kept;
                _status = kept ? '已加入收藏' : '已取消收藏';
              });
            }),
            _action('换源', Icons.visibility_outlined, () {
              if (flags.length <= 1) {
                setState(() => _status = '仅一条线路，无法换源');
                return;
              }
              final next = (_flagIdx + 1) % flags.length;
              _selectFlag(next);
            }),
            _action('解析', Icons.tune_rounded, () => _pickParse()),
          ],
        ),
        ),
      );
    }

    Widget lower() {
      final pillH = compact ? 28.0 : 36.0;
      final pillFs = compact ? 12.0 : 15.0;
      final epH = compact ? 32.0 : 42.0;
      final epFs = compact ? 12.0 : 14.0;
      final gap = compact ? 6.0 : 10.0;
      final srcLabelFs = compact ? 13.0 : 16.0;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(height: compact ? 8 : 10),
          Row(
            children: [
              Text('视频来源', style: TextStyle(color: fg, fontSize: srcLabelFs, fontWeight: FontWeight.w700)),
              SizedBox(width: compact ? 8 : 14),
              Expanded(
                child: SizedBox(
                  height: pillH + 2,
                  child: HScrollList(
                    itemCount: flags.length,
                    separatorBuilder: (_, __) => SizedBox(width: compact ? 6 : 8),
                    itemBuilder: (_, i) => AppPill(
                      label: flags[i].show,
                      height: pillH,
                      fontSize: pillFs,
                      selected: i == _flagIdx,
                      onTap: () {
                        if (i == _flagIdx) return;
                        _selectFlag(i);
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (pageCount > 1) ...[
            SizedBox(height: compact ? 8 : 10),
            SizedBox(
              height: pillH,
              child: HScrollList(
                itemCount: pageCount,
                separatorBuilder: (_, __) => SizedBox(width: compact ? 6 : 8),
                itemBuilder: (_, i) {
                  final from = i * _epSize + 1;
                  final to = ((i + 1) * _epSize).clamp(0, eps.length);
                  return AppPill(
                    label: '$from-$to',
                    height: pillH,
                    fontSize: pillFs,
                    selected: i == _epPage,
                    onTap: () => setState(() => _epPage = i),
                  );
                },
              ),
            ),
          ],
          SizedBox(height: compact ? 8 : 12),
          if (pageEps.isEmpty)
            Text('无剧集', style: TextStyle(color: muted))
          else
            LayoutBuilder(
              builder: (context, c) {
                final cols = compact ? 3 : 6;
                final w = (c.maxWidth - gap * (cols - 1)) / cols;
                return Wrap(
                  spacing: gap,
                  runSpacing: gap,
                  children: [
                    for (var i = 0; i < pageEps.length; i++)
                      SizedBox(
                        width: w,
                        height: epH,
                        child: EpisodeChip(
                          label: pageEps[i].name,
                          selected: _epIdx == _epPage * _epSize + i,
                          autofocus: false,
                          height: epH,
                          fontSize: epFs,
                          onTap: () => _playAt(_epPage * _epSize + i),
                        ),
                      ),
                  ],
                );
              },
            ),
        ],
      );
    }

    if (compact) {
      return Focus(
        canRequestFocus: false,
        onKeyEvent: _onInlinePlayerKey,
        child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 36),
            children: [
              videoPane(expand: false),
              const SizedBox(height: 12),
              Text(
                d.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: fg, fontSize: 22, fontWeight: FontWeight.w700, height: 1.25),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 16,
                runSpacing: 6,
                children: [
                  _meta('更新：${d.remarks.isEmpty ? '暂无' : d.remarks}'),
                  _meta('来源：${d.site.isEmpty ? '未知' : d.site}'),
                  _meta('年份：${d.year.isEmpty ? '暂无' : d.year}'),
                  if (d.area.isNotEmpty) _meta('地区：${d.area}'),
                ],
              ),
              const SizedBox(height: 8),
              metaBlock(),
              const SizedBox(height: 4),
              Text(_status, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: muted.withOpacity(0.85), fontSize: 12)),
              const SizedBox(height: 6),
              actionRow(),
              lower(),
            ],
          )
      );
    }

    return Focus(
      canRequestFocus: false,
      onKeyEvent: _onInlinePlayerKey,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 略压缩上半区，避免简介区与「视频来源」之间大块空档
          final upperH = (constraints.maxHeight * 0.44).clamp(320.0, 440.0);
          return ListView(
            padding: const EdgeInsets.fromLTRB(48, 8, 48, 36),
            children: [
              SizedBox(
                height: upperH,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 42, child: videoPane(expand: true)),
                    const SizedBox(width: 28),
                    Expanded(
                      flex: 58,
                      child: Padding(
                      padding: const EdgeInsets.only(top: 4, bottom: 2),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            d.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: fg,
                              fontSize: 28,
                              fontWeight: FontWeight.w700,
                              height: 1.25,
                              letterSpacing: 0.3,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 20,
                            runSpacing: 6,
                            children: [
                              _meta('更新：${d.remarks.isEmpty ? '暂无' : d.remarks}'),
                              _meta('来源：${d.site.isEmpty ? '未知' : d.site}'),
                              _meta('年份：${d.year.isEmpty ? '暂无' : d.year}'),
                              if (d.area.isNotEmpty) _meta('地区：${d.area}'),
                            ],
                          ),
                          const SizedBox(height: 8),
                          metaBlock(),
                          const Spacer(),
                          Text(
                            _status,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: muted.withOpacity(0.85), fontSize: 12),
                          ),
                          const SizedBox(height: 6),
                          actionRow(),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            lower(),
          ],
          );
        },
      ),
    );
  }

  Future<void> _pickParse() async {
    try {
      final st = await ref.read(apiProvider).getSettings();
      final parses = ((st['parses'] as List?) ?? []).whereType<Map>().toList();
      if (parses.isEmpty) {
        setState(() => _status = '当前配置无解析器');
        return;
      }
      final names = parses.map((e) => '${e['name'] ?? ''}').where((e) => e.isNotEmpty).toList();
      final cur = '${(st['settings'] as Map?)?['preferredParse'] ?? ''}';
      final picked = await showDialog<String>(
        context: context,
        useRootNavigator: true,
        builder: (ctx) {
          final pal = KotvPalette.of(ctx);
          return SimpleDialog(
            backgroundColor: pal.dialogBg,
            title: Text('选择解析器', style: TextStyle(color: pal.fg)),
            children: [
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, ''),
                child: Text('自动（默认）${cur.isEmpty ? '  ✓' : ''}', style: TextStyle(color: pal.fg)),
              ),
              for (final n in names)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, n),
                  child: Text('$n${cur == n ? '  ✓' : ''}', style: TextStyle(color: pal.fg)),
                ),
            ],
          );
        },
      );
      if (picked == null) return;
      await ref.read(apiProvider).setSetting('preferredParse', picked);
      setState(() => _status = picked.isEmpty ? '解析器: 自动' : '解析器: $picked');
      if (_epIdx >= 0) _playAt(_epIdx);
    } catch (e) {
      setState(() => _status = '$e');
    }
  }

  Widget _meta(String t) {
    final p = KotvPalette.of(context);
    return Text(
      t,
      style: TextStyle(color: p.muted, fontSize: 14.5, height: 1.3),
    );
  }

  String _quickSearchQuery(VodDetail d) {
    var q = d.actor.trim();
    if (q.isEmpty || q == '暂无') return d.name;
    for (final sep in [',', '，', '/', '、', ' ']) {
      final i = q.indexOf(sep);
      if (i > 0) {
        q = q.substring(0, i).trim();
        break;
      }
    }
    return q.isEmpty ? d.name : q;
  }

  void _showVodMeta(VodDetail d) {
    final p = KotvPalette.of(context);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.dialogBg,
        title: Text(d.name, style: TextStyle(color: p.fg)),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Text(
              '导演：${d.director.isEmpty ? '暂无' : d.director}\n'
              '演员：${d.actor.isEmpty ? '暂无' : d.actor}\n'
              '类型：${d.typeName.isEmpty ? '暂无' : d.typeName}\n'
              '年份：${d.year.isEmpty ? '暂无' : d.year}\n'
              '地区：${d.area.isEmpty ? '暂无' : d.area}\n'
              '备注：${d.remarks.isEmpty ? '暂无' : d.remarks}\n\n'
              '${d.content.isEmpty ? '暂无简介' : d.content.replaceAll(RegExp(r'<[^>]*>'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim()}',
              style: TextStyle(color: p.muted, height: 1.55, fontSize: 15),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('关闭', style: TextStyle(color: p.primary))),
        ],
      ),
    );
  }

  Widget _action(String label, IconData icon, VoidCallback onTap) {
    final p = KotvPalette.of(context);
    final compact = KotvLayout.isCompact(context) || KotvLayout.useBottomNav(context);
    final s = LayoutScale.layoutOf(context);
    final w = (compact ? 48.0 : 72.0) * (compact ? 1.0 : s.clamp(0.75, 1.0));
    final h = (compact ? 36.0 : 56.0) * (compact ? 1.0 : s.clamp(0.75, 1.0));
    final iconSz = compact ? 14.0 : 20.0;
    final fs = compact ? 9.0 : 11.0;
    final gap = compact ? 1.0 : 4.0;
    final radius = compact ? 7.0 : 10.0;
    return Padding(
      padding: EdgeInsets.only(right: compact ? 4 : 8),
      child: TvFocus(
        onPressed: onTap,
        borderRadius: radius,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(radius),
            child: Ink(
              width: w,
              height: h,
              decoration: BoxDecoration(
                color: p.pillBg,
                borderRadius: BorderRadius.circular(radius),
                border: Border.all(color: p.pillBorder),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: p.fg, size: iconSz),
                  SizedBox(height: gap),
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: p.fg.withOpacity(0.85), fontSize: fs, height: 1.1),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
