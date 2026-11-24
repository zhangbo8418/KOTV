import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kDoubleTapTimeout, kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../api/kotv_api.dart';
import '../api/kotv_engine_url.dart';
import '../desktop/mini_player_window.dart';
import '../models/models.dart';
import '../player/audio_stage.dart';
import '../player/danmaku_layer.dart';
import '../player/external_player.dart';
import '../player/exo_playback.dart';
import '../player/fvp_playback.dart';
import '../player/html_playback.dart';
import '../player/art_playback.dart';
import '../player/xg_playback.dart';
import '../player/zw_playback.dart';
import '../player/buffer_budget.dart';
import '../player/disc_play.dart';
import '../player/fullscreen_mode.dart';
import '../player/kotv_platform.dart';
import '../player/background_playback.dart';
import '../player/kotv_playback.dart';
import '../player/mini_playback.dart';
import '../player/kotv_player_factory.dart';
import '../player/kotv_win_chrome.dart';
import '../player/mpv_opts.dart';
import '../player/playback_settings.dart';
import '../player/native_mpv_playback.dart';
import '../player/mpv_underlay.dart';
import '../player/play_headers.dart';
import '../player/player_normalize.dart';
import '../player/subtitle_style_util.dart';
import '../player/playback_failover.dart';
import '../player/tv_remote_keys.dart';
import '../providers.dart';
import '../nav/kotv_page.dart';
import '../nav/kotv_routes.dart';
import '../api/kotv_settings_cache.dart';
import '../remote/local_collect.dart';
import '../remote/local_download.dart';
import '../remote/postmsg_host.dart';
import '../remote/remote_bridge.dart';
import '../vod/vod_open.dart';
import '../theme/layout_scale.dart';
import '../theme/kotv_palette.dart';
import '../theme/kotv_theme.dart';
import '../theme/stable_focus.dart';
import '../util/kotv_app_dirs.dart';
import '../vod/content_clicker.dart';
import '../widgets/auth_gate.dart';
import '../widgets/buffering_overlay.dart';
import '../widgets/cast_flow.dart';
import '../widgets/danmaku_search_dialog.dart';
import '../policy/group_policy.dart';
import '../widgets/chrome.dart';
import '../widgets/focus_arm.dart';
import '../widgets/kotv_tv_text_field.dart';
import '../widgets/h_scroll.dart';
import '../widgets/kotv_network_image.dart';
import '../widgets/mini_hover_shell.dart';
import '../widgets/vod_player_chrome.dart';
import 'detail_fullscreen.dart';
import 'download_screen.dart';
import 'folder_screen.dart';
import 'shell.dart';

class DetailScreen extends ConsumerStatefulWidget {
  const DetailScreen({
    super.key,
    required this.id,
    this.site = '',
    this.title = '',
    this.mark = '',
  });

  final String id;
  final String site;
  final String title;
  /// 从目录点文件时按集名匹配并起播。
  final String mark;

  /// 详情是否在栈上（含播放中 PopScope.canPop=false）。
  static bool get isOpen => _DetailScreenState._active != null;

  /// 当前路由就是这一页（上面没有目录等再压的页面）。
  static bool get isForeground {
    final active = _DetailScreenState._active;
    if (active == null || !active.mounted) return false;
    return ModalRoute.of(active.context)?.isCurrent == true;
  }

  /// 正在看的片子就是这一部（入口 id 或详情返回的 id）。
  static bool matches(String id, String site) {
    final active = _DetailScreenState._active;
    if (active == null || !active.mounted) return false;
    if (active._routeSite.trim() != site.trim()) return false;
    final want = id.trim();
    if (want.isEmpty) return false;
    return active._routeId.trim() == want || active._detailId().trim() == want;
  }

  /// 已打开的详情换成另一部，不压新路由。
  static Future<void> retarget({
    required String id,
    required String site,
    required String title,
    required String mark,
  }) async {
    final active = _DetailScreenState._active;
    if (active == null || !active.mounted) return;
    await active._retarget(
      id: id,
      site: site,
      title: title,
      mark: mark,
    );
  }

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

  /// 换源/切 Tab：放开 PopScope，并 await 硬停（含 MPV dispose），避免卸树后仍占 AO/出声。
  /// 并发调用挂同一 Completer。硬停等待有上限以便 UI 返回。
  static Future<void> prepareLeave() async {
    final inFlight = _DetailScreenState._leaveDone;
    if (inFlight != null) {
      try {
        await inFlight.future.timeout(const Duration(seconds: 5));
      } catch (_) {}
      return;
    }
    final active = _DetailScreenState._active;
    if (active == null) return;
    if (active._stoppedHard) {
      await active._releasePopGuard();
      return;
    }
    final done = Completer<void>();
    _DetailScreenState._leaveDone = done;
    active._leaving = true;
    try {
      // 须完整退沉浸（系统栏/方向 + setState）；禁止只改布尔，否则树与 Surface 错位。
      if (active._immersiveFullscreen) {
        try {
          await active._exitImmersiveFullscreen();
        } catch (_) {}
      } else {
        try {
          active.ref.read(detailImmersiveFullscreenProvider.notifier).state = false;
        } catch (_) {}
      }
      // 立刻清 _active：否则 goKotvPage→prepareLeave 仍会 await 本页硬停，切 Tab 像点不动。
      if (_DetailScreenState._active == active) {
        _DetailScreenState._active = null;
      }
      try {
        active._chromeCover.release(active.ref.read(detailChromeCoverProvider.notifier));
      } catch (_) {}
      // 短超时 flush/先 pause 消音不挡返回；完整拆机仍走 [_stopHard]（其内再 soft pause，幂等）。
      try {
        await active
            ._flushWatchProgress(force: true)
            .timeout(const Duration(milliseconds: 400));
      } catch (_) {}
      try {
        await kotvSoftPausePlayers(
          <KotvPlayback?>[
            active._fvp,
            active._mk,
            active._exo,
            active._html,
            active._art,
            active._xg,
            active._zw,
          ],
        ).timeout(const Duration(milliseconds: 400));
      } catch (_) {}
      await active._stopHardAwait(skipFlush: true);
      if (active._miniDesktop) {
        active._miniDesktop = false;
        try {
          await MiniPlayerWindow.exit();
        } catch (_) {}
      }
      await active._releasePopGuard();
    } finally {
      if (!done.isCompleted) done.complete();
      if (_DetailScreenState._leaveDone == done) {
        _DetailScreenState._leaveDone = null;
      }
    }
  }

  @override
  ConsumerState<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends ConsumerState<DetailScreen> with WidgetsBindingObserver {
  static _DetailScreenState? _active;
  /// 进行中的离开/硬停；并发 [prepareLeave]/[_leavePage] 挂此等待。
  static Completer<void>? _leaveDone;
  VodDetail? _detail;
  String? _error;
  bool _loading = true;
  int _flagIdx = 0;
  /// 最近一次真正起播时的线路；进度/预加载认这个，避免焦点浏览线路污染。
  int _playFlagIdx = 0;
  int _epIdx = -1;
  /// 全屏页在父 setState 下更新；保留 GlobalKey 仅供自动切集动画。
  final GlobalKey<DetailFullscreenPageState> _fsPageKey = GlobalKey<DetailFullscreenPageState>();
  /// 上下滑切集：稳定视频层与全屏控件共用位移。
  final ValueNotifier<double> _fsSwipeDy = ValueNotifier<double>(0);
  /// 详情内嵌：菜单键弹出后播停键自动获焦。
  bool _chromeRemoteFocus = false;
  final GlobalKey<VodInlineControlsState> _inlineChromeKey =
      GlobalKey<VodInlineControlsState>();
  /// Win7 内嵌底栏占位（量锚点）；非 Win7 仍用 [VodInlineControls]。
  final GlobalKey _inlineChromeAnchorKey = GlobalKey(debugLabel: 'kotv_inline_chrome_anchor');
  /// Win7 画面区（含底栏 Stack）锚点，弹幕只盖此矩形。
  final GlobalKey _inlineSurfaceKey = GlobalKey(debugLabel: 'kotv_inline_surface');
  int _winChromeToken = 0;
  /// Win7 内嵌 / 迷你推送去抖快照（几何/播态/量化进度）。
  String? _lastWinInlineChromeSnap;
  /// Win7 视频 HWND 几何去抖，避免进度 notify 反复 updateFrame/RaiseChrome。
  String? _lastWinVideoFrameSig;
  /// Win7 原生手势层单击延迟（等双击判定）与按下点。
  Timer? _winInlineTapTimer;
  late final KotvWinBufferText _winBuffer = KotvWinBufferText(() {
    if (mounted) _syncWinInlineChrome();
  });
  Offset? _winInlineDownAt;
  int _epPage = 0;
  /// 焦点停留后切换线路 / 分集区间。
  final KotvFocusArm _detailFocusArm = KotvFocusArm();
  bool _reversed = false;
  /// 起播续播 seek（毫秒）；仅当目标集 remarks/flag 与历史一致时并入 startAt。
  int _resumeSeekMs = 0;
  String _resumeSeekRemarks = '';
  String _resumeSeekFlag = '';
  DateTime? _lastProgressSave;
  String _configSource = '';
  bool _kept = false;
  String _status = '选择剧集开始播放';
  String _playUrl = '';
  Map<String, String> _playHeaders = const {};
  String _decodeMode = 'auto';
  /// 设置/用户所选解码；failover 无画面时临时改软解，只改 [_decodeMode]。
  String _prefDecodeMode = 'auto';
  String _renderMode = 'surface';
  KotvMpvOpts _mpvOpts = const KotvMpvOpts();
  bool _danmakuOn = false;
  bool _ambientOn = false;

  /// Win7 原生播控没有氛围模式：设置里残留的开关一律当关。
  static bool _ambientFromSetting(String v) => !KotvWinChrome.isNeeded && v.toLowerCase() == 'true';
  /// off | audio | pip
  String _playerBackground = 'pip';
  double _holdSpeed = 2.0;
  bool _stableVolumeOn = false;
  /// 本集 play 返回的片源弹幕；改弹幕设置后带着它重新让引擎选源。
  List<DanmakuSource> _spiderDanmakuSources = const [];
  /// 猫爪 danmuPush 的弹幕 URL；集加载时并入源列表，禁止无脑清空已推送轨。
  String? _nodeDanmuPushUrl;
  double _danmakuSize = 18;
  double _danmakuOpacity = 0.85;
  int _danmakuRows = 6;
  int _danmakuMaxOnScreen = 150;
  double _danmakuScrollArea = 0.5;
  bool _danmakuShowScroll = true;
  bool _danmakuShowTop = true;
  bool _danmakuShowBottom = true;
  bool _danmakuShowReverse = true;
  bool _danmakuShowSpecial = true;
  bool _danmakuShowPositioned = true;
  bool _danmakuBold = false;
  int _danmakuDurationMs = 8000;
  int _danmakuFixedDurationMs = 5000;
  double _danmakuLineSpacing = 1.4;
  String _danmakuStrokeMode = 'outline';
  String _danmakuColorMode = 'original';
  String _danmakuFontFamily = 'default';
  int _danmakuRowsTop = 3;
  int _danmakuRowsBottom = 3;
  double _danmakuScrollGap = 0.08;
  double _danmakuStrokeWidth = 0.12;
  double _danmakuShadowOpacity = 0.5;
  double _danmakuProjectionOffsetX = 0.08;
  double _danmakuProjectionOffsetY = 0.08;
  double _danmakuProjectionOpacity = 0.2;
  int _danmakuSourceIdx = 0;
  List<DanmakuSource> _danmakuSources = const [];
  double _danmakuOffsetSec = 0;
  final ValueNotifier<List<DanmakuItem>> _danmakuItems = ValueNotifier(const []);
  AspectSpec _aspect = const AspectSpec(key: 'default', fit: BoxFit.contain);
  int _openingSec = 0;
  int _endingSec = 0;
  bool _skipOpeningEnding = true;
  String _playerVal = kotvDefaultVodPlayer();
  /// 设置/用户所选播放器；failover 临时切换只改 [_playerVal]。
  String _prefPlayerVal = kotvDefaultVodPlayer();
  /// 设置「自动切换播放器」：auto=开，off=关。
  String _prefPlayerFailover = 'auto';
  bool _miniDesktop = false;
  /// 与直播页一致：原位全屏，同一 PlatformView/Texture 放大，不 push 第二块 Surface。
  bool _immersiveFullscreen = false;
  /// 退全屏两阶段：标志已清但 Stable 层仍用整屏几何，等量槽后再缩，避免 Hybrid/FVP 卸挂。
  bool _holdImmersiveVideoGeom = false;
  /// 进出全屏串行队列，防止快速来回交错跳过量槽。
  Future<void> _immersiveTransit = Future.value();
  /// Android 全屏换集过渡盖：仅 Hybrid Surface 防镂空透底；桌面不用。
  bool _immersiveEpCover = false;
  /// 退出全屏后短时挡住「再 pop 详情」，避免双通道返回直接回首页。
  DateTime? _suppressDetailPopUntil;
  DateTime? _immersiveBackUntil;
  KotvDesktopFullscreenKind _desktopFs = KotvDesktopFullscreenKind.window;
  final GlobalKey _videoHostKey = GlobalKey(debugLabel: 'kotv_detail_video');
  /// 稳定视频层在详情 Stack 内的矩形（含位置）。全屏进出只改几何，
  /// 勿在 Follower / 直挂 Positioned 间切换子树（Android Hybrid Surface 卸挂会定住）。
  final GlobalKey _videoSlotKey = GlobalKey(debugLabel: 'kotv_detail_video_slot');
  final GlobalKey _detailStackKey = GlobalKey(debugLabel: 'kotv_detail_stack');
  final GlobalKey _bodyClipKey = GlobalKey(debugLabel: 'kotv_detail_body_clip');
  Rect? _videoLayerRect;
  /// 顶栏下 Expanded 在详情 Stack 内的矩形。画面叠在 Scaffold 上，
  /// 必须裁到此区域，否则滚动/错位时会盖住返回与片名。
  Rect? _bodyClipRect;
  /// 上一帧有效绘制矩形；全屏进出短暂量不到黑槽时复用，避免卸掉 Hybrid Surface。
  Rect? _lastVideoPaintRect;
  bool _videoSlotSyncScheduled = false;
  /// 当前是否磁力/BT 本地流（状态文案与卡顿语义不同）。
  bool _magnetPlay = false;
  Timer? _btProgressTimer;
  static const _epSize = 20;
  double? _prefSpeed;
  double? _prefVolume;

  KotvPlayback? _mk;
  ExoPlayback? _exo;
  FvpPlayback? _fvp;
  HtmlPlayback? _html;
  ArtPlayback? _art;
  XgPlayback? _xg;
  ZwPlayback? _zw;
  StreamSubscription? _endedSub;
  StreamSubscription? _queuedStartSub;
  StreamSubscription<Duration>? _posSub;
  KotvPlayback? _wiredNotifyTarget;
  VoidCallback? _playbackNotify;
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
  /// 单集循环：本页只存这一份，每次起播下发给当前播放器，换集、换播放器都不丢。
  bool _repeatOne = false;
  DateTime? _sessionStartedAt;
  KotvApi? _api;
  /// 下一集 play 预解析缓存（flag|index → 引擎 play 返回）。
  final Map<String, Map<String, dynamic>> _nextPlayCache = {};
  int _nextPreloadSerial = 0;
  /// 本集是否已发起「预加载下一集」（离片尾 [_nextEpisodeQueueLeadMs] 时发起一次）。
  bool _nextPreloadRequested = false;
  /// 已排进当前播放器播放列表的下一集；播到它时由 [_onQueuedEpisodeStarted] 记账。
  ({String key, int idx, String playUrl, Map<String, String> headers, Map<String, dynamic> data})? _queuedNext;
  /// 无缝进入下一集后、真正开播前出错：退回普通换集（带自动切换播放器）。
  bool _queuedEpisodeUnconfirmed = false;
  /// 进度回调里记下的本集时长；无缝换集时给上一集写完播进度。
  int _tickDurationMs = 0;
  /// 详情接口 magnet：展开/取消磁力任务用（DTO 可能已清空须引擎集的 url）。
  bool _detailMagnet = false;
  /// 详情接口 expand：磁力或 YouTube 播放列表等须异步展开。
  bool _detailExpand = false;
  bool _preloadNextEpisode = false;
  /// 去广告开关（与开播 / 无缝排队共用，避免默认 true 与设置脱节）。
  bool _adFilterOn = true;
  RemoteBridge? _boundRemote;
  String _routeId = '';
  String _routeSite = '';
  String _routeTitle = '';
  final List<({String site, String id})> _emptyTried = [];
  bool _emptyFallbackExhausted = false;
  String _routeMark = '';
  KotvEmbedBackend get _backend => kotvEmbedBackend(_playerVal);

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

  /// 已有后端实例；勿在 build/浮层里触发 [_ensureMpv] 等惰性创建。
  KotvPlayback? get _existingPlayback {
    switch (_backend) {
      case KotvEmbedBackend.html:
        return _html;
      case KotvEmbedBackend.art:
        return _art;
      case KotvEmbedBackend.xg:
        return _xg;
      case KotvEmbedBackend.zw:
        return _zw;
      case KotvEmbedBackend.fvp:
        return _fvp;
      case KotvEmbedBackend.exo:
        return _exo;
      case KotvEmbedBackend.mpv:
        return _mk;
    }
  }

  String get _enginePrefix => flutterPlayerLabel(_playerVal);

  bool get _isBuffering {
    if (_playUrl.isEmpty) return false;
    final p = _existingPlayback;
    return p != null && p.stalling;
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

  KotvPlayback _ensureMpv() =>
      _mk ??= NativeMpvPlayback(opts: _mpvOpts.copyWith(decodeMode: _decodeMode));

  /// 卸本页 MPV 会话（换引擎时调用）；硬切 [_playAt] / 无缝不调用。
  Future<void> _releaseOwnedMpv() async {
    final mk = _mk;
    _mk = null;
    await kotvReleaseOwnedMpv(mk);
  }

  /// 起播无画面：按 [kotvPlanSilentRecover] 换解码 / 换引擎。
  /// `true` = 外层 for continue；`false` = break；`null` = 会话已作废，直接 return。
  Future<bool?> _recoverAfterSilentVideo({
    required KotvPlayback pb,
    required KotvPlaybackFailover failover,
    required int serial,
  }) async {
    final plan = kotvPlanSilentRecover(failover: failover);

    switch (plan.action) {
      case KotvSilentRecoverAction.keepSession:
      case KotvSilentRecoverAction.giveUp:
        return false;
      case KotvSilentRecoverAction.applyStep:
        final step = plan.step!;
        if (kotvIsApple() && pb is NativeMpvPlayback) {
          // macOS / iOS：停播藏层，保留 libmpv/ASBDL，切回后 EDR 会话仍在。
          try {
            await pb.stop();
          } catch (_) {}
        } else {
          try {
            await pb.release();
          } catch (_) {
            try {
              await pb.stop();
            } catch (_) {}
          }
        }
        await _stopInactiveBackends(kotvEmbedBackend(step.playerVal));
        if (!mounted || serial != _playAtSerial) return null;
        setState(() {
          _playerVal = step.playerVal;
          _decodeMode = step.decodeMode;
          _status = step.status;
        });
        _syncFullscreen();
        return true;
    }
  }

  /// 硬停并限时等待（便于 UI 返回）。超时不取消底层拆机；桌面再建前等拆机门闩。
  Future<void> _stopHardAwait({bool skipFlush = false, Duration timeout = const Duration(seconds: 8)}) async {
    try {
      await _stopHard(skipFlush: skipFlush).timeout(timeout);
    } catch (_) {}
  }

  /// 切到其它内置后端时停掉闲置引擎。
  /// 调用方须在改 [_playerVal] **之前**调用，以便旧 FVP/Surface 仍在树上时完成 release。
  /// 先 pause 再 stop/release；离开 MPV 时桌面也要 dispose Player，避免双引擎抢 AO。
  Future<void> _stopInactiveBackends(KotvEmbedBackend keep) async {
    if (keep != KotvEmbedBackend.mpv) {
      if (kotvIsApple() && _mk is NativeMpvPlayback) {
        // 保留原生 MPV 会话，仅 stop 藏层，避免换引擎后 EDR 从零重建。
        try {
          await _mk!.stop();
        } catch (_) {}
      } else {
        await _releaseOwnedMpv();
      }
    }
    if (keep != KotvEmbedBackend.fvp) {
      // 须拆掉实例：仅 stop 时 mdk 包缓存/纹理可能残留（ADB: ReleaseRT 后 PSS/Graphics 仍涨）。
      // 先 stop/dispose 再置空，避免 [_playback] 在中途 new 出第二个 FVP。
      final fvp = _fvp;
      await kotvSoftPausePlayers([fvp]);
      try {
        await fvp?.stop();
      } catch (_) {}
      kotvDisposePlaybackWrappers([fvp]);
      if (identical(_fvp, fvp)) _fvp = null;
    }
    if (keep != KotvEmbedBackend.exo) {
      // release 拆掉 ExoPlayer 和 Texture。stop 只卸文件，换引擎必须走 release。
      final exo = _exo;
      await kotvSoftPausePlayers([exo]);
      try {
        await exo?.release();
      } catch (_) {}
      kotvDisposePlaybackWrappers([exo]);
      if (identical(_exo, exo)) _exo = null;
    }
    if (keep != KotvEmbedBackend.html) {
      await kotvSoftPausePlayers([_html]);
      try {
        await _html?.stop();
      } catch (_) {}
    }
    if (keep != KotvEmbedBackend.art) {
      await kotvSoftPausePlayers([_art]);
      try {
        await _art?.stop();
      } catch (_) {}
    }
    if (keep != KotvEmbedBackend.xg) {
      await kotvSoftPausePlayers([_xg]);
      try {
        await _xg?.stop();
      } catch (_) {}
    }
    if (keep != KotvEmbedBackend.zw) {
      await kotvSoftPausePlayers([_zw]);
      try {
        await _zw?.stop();
      } catch (_) {}
    }
  }

  /// 硬切换集/换源：经 [kotvStopPlayersForEpisodeSwitch]（先 pause 消音再卸文件）。实例默认保留。
  /// 无缝走 [skipToNext] / [queuedStartStream]，不调用本方法，也不经 [_playAt]。
  Future<void> _stopAllBackends() async {
    await kotvStopPlayersForEpisodeSwitch([
      _mk,
      _fvp,
      _exo,
      _html,
      _art,
      _xg,
      _zw,
    ]);
  }

  @override
  void initState() {
    super.initState();
    _routeId = widget.id;
    _routeSite = widget.site;
    _routeTitle = widget.title;
    _routeMark = widget.mark;
    WidgetsBinding.instance.addObserver(this);
    // Win7：滑动切集时画面层只换 Positioned.top，mpv 子窗要跟着重新摆。
    if (KotvWinChrome.isNeeded) _fsSwipeDy.addListener(KotvMpvUnderlayHole.resyncAll);
    _api = ref.read(apiProvider);
    _active = this;
    detailImmersiveBack = _handleImmersiveBack;
    _chromeCover.holdAfterFrame(context, () => mounted, () => ref.read(detailChromeCoverProvider.notifier));
    kotvRegisterQuitHook(_prepareQuit);
    MiniPlayerWindow.onAndroidPipChanged = (inPip) {
      if (!mounted) return;
      setState(() => _miniDesktop = inPip);
    };
    _load();
    WidgetsBinding.instance.addPostFrameCallback((_) => _attachRemoteHandlers());
  }

  Future<void> _retarget({
    required String id,
    required String site,
    required String title,
    required String mark,
  }) async {
    _routeId = id;
    _routeSite = site;
    _routeTitle = title;
    _routeMark = mark;
    _emptyTried.clear();
    _emptyFallbackExhausted = false;
    _epIdx = -1;
    _flagIdx = 0;
    if (_miniDesktop) {
      try {
        await _exitMini();
      } catch (_) {}
    }
    await _stopHardAwait();
    _stoppedHard = false;
    if (!mounted || _active != this) return;
    await _load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    kotvApplyPlayerBackground(
      state,
      mode: _playerBackground,
      playing: _playback.playing,
      hasMedia: _playUrl.isNotEmpty,
      pause: _playback.pause,
      setVideo: _playback.setVideoOutputEnabled,
    );
  }

  void _attachRemoteHandlers() {
    // 猫爪 danmuPush → 当前详情页弹幕轨（本机/远端都走 PostMsg）。
    PostMsgHost.onDanmuPush = _onNodeDanmuPush;
    final bridge = ref.read(remoteBridgeProvider);
    if (bridge == null) return;
    _boundRemote = bridge;
    bridge.onControl = _onRemoteControl;
    bridge.onSubtitleFile = _onRemoteSubtitle;
    bridge.onDanmakuFile = _onRemoteDanmakuFile;
    bridge.onLiveDanmaku = _onRemoteLiveDanmaku;
    bridge.onDetailRefresh = _onRemoteDetailRefresh;
    bridge.onPlayerRefresh = _onRemotePlayerRefresh;
  }

  void _detachRemoteHandlers() {
    final bridge = _boundRemote;
    _boundRemote = null;
    if (identical(PostMsgHost.onDanmuPush, _onNodeDanmuPush)) {
      PostMsgHost.onDanmuPush = null;
    }
    if (bridge == null) return;
    if (identical(bridge.onControl, _onRemoteControl)) bridge.onControl = null;
    if (identical(bridge.onSubtitleFile, _onRemoteSubtitle)) bridge.onSubtitleFile = null;
    if (identical(bridge.onDanmakuFile, _onRemoteDanmakuFile)) bridge.onDanmakuFile = null;
    if (identical(bridge.onLiveDanmaku, _onRemoteLiveDanmaku)) bridge.onLiveDanmaku = null;
    if (identical(bridge.onDetailRefresh, _onRemoteDetailRefresh)) bridge.onDetailRefresh = null;
    if (identical(bridge.onPlayerRefresh, _onRemotePlayerRefresh)) bridge.onPlayerRefresh = null;
  }

  void _onNodeDanmuPush(String url) {
    final u = url.trim();
    if (!mounted || u.isEmpty) return;
    final serial = _playAtSerial;
    _nodeDanmuPushUrl = u;
    _ensureDanmakuPushSource(u);
    unawaited(() async {
      final idx = _danmakuSources.indexWhere((s) => s.url == u);
      if (idx < 0) return;
      await _loadDanmakuSource(idx, playSerial: serial);
      if (!mounted || serial != _playAtSerial) return;
      if (!_danmakuOn) setState(() => _danmakuOn = true);
    }());
  }

  /// 把猫爪推送 URL 登记进片源列表与当前可选源（集加载共用）。
  void _ensureDanmakuPushSource(String url) {
    final u = url.trim();
    if (u.isEmpty) return;
    if (!_spiderDanmakuSources.any((s) => s.url == u)) {
      _spiderDanmakuSources = [
        DanmakuSource(name: '推送', url: u),
        ..._spiderDanmakuSources,
      ];
    }
    final existing = _danmakuSources.indexWhere((s) => s.url == u);
    if (existing >= 0) {
      if (_danmakuSourceIdx != existing) {
        setState(() => _danmakuSourceIdx = existing);
      }
      return;
    }
    setState(() {
      _danmakuSources = [DanmakuSource(name: '推送', url: u), ..._danmakuSources];
      _danmakuSourceIdx = 0;
    });
  }

  void _onRemoteDetailRefresh() {
    if (!mounted) return;
    unawaited(_load());
  }

  void _onRemotePlayerRefresh() {
    if (!mounted || _epIdx < 0) return;
    unawaited(_playAt(_epIdx));
  }

  void _onRemoteControl(String type, int seekMs) {
    if (!mounted) return;
    final t = type.trim().toLowerCase();
    switch (t) {
      case 'prev':
        if (_epIdx > 0) unawaited(_playAt(_epIdx - 1));
        break;
      case 'next':
        unawaited(_advanceToNextEpisode(fromEnd: false));
        break;
      case 'replay':
        if (_playUrl.isEmpty) return;
        unawaited(() async {
          await _playback.seek(Duration.zero);
          await _playback.play();
        }());
        break;
      case 'repeat':
        if (_playUrl.isEmpty) return;
        unawaited(_setRepeatOne(!_repeatOne));
        break;
      case 'play':
        if (_playUrl.isEmpty) return;
        unawaited(_playback.play());
        break;
      case 'pause':
        if (_playUrl.isEmpty) return;
        unawaited(_playback.pause());
        break;
      case 'toggle':
      case 'playpause':
      case 'play_pause':
        if (_playUrl.isEmpty) return;
        unawaited(_playback.playOrPause());
        break;
      case 'seek':
        if (_playUrl.isEmpty || _playback.isLive) return;
        if (seekMs > 0) {
          unawaited(_playback.seek(Duration(milliseconds: seekMs)));
        }
        break;
      case 'forward':
      case 'forward10':
        if (_playUrl.isEmpty || _playback.isLive) return;
        final ms = seekMs > 0 ? seekMs : 10000;
        unawaited(_playback.seek(_playback.position + Duration(milliseconds: ms)));
        break;
      case 'backward':
      case 'rewind':
      case 'back10':
        if (_playUrl.isEmpty || _playback.isLive) return;
        final ms = seekMs > 0 ? seekMs : 10000;
        final next = _playback.position - Duration(milliseconds: ms);
        unawaited(_playback.seek(next.isNegative ? Duration.zero : next));
        break;
      case 'stop':
        unawaited(_stopHardAwait());
        break;
    }
  }

  void _onRemoteSubtitle(String path) {
    if (!mounted) return;
    unawaited(_playback.addSubtitlePath(path));
  }

  /// 遥控推送的弹幕文件（引擎本机路径或 URL），由引擎读取解析。
  void _onRemoteDanmakuFile(String path) {
    if (!mounted || path.trim().isEmpty) return;
    unawaited(() async {
      final items = await _fetchDanmaku(path.trim());
      if (!mounted || items == null) return;
      _danmakuItems.value = items;
      if (!_danmakuOn) setState(() => _danmakuOn = true);
    }());
  }

  void _onRemoteLiveDanmaku(DanmakuItem item) {
    if (!mounted) return;
    _danmakuItems.value = kotvAppendLiveDanmaku(_danmakuItems.value, item, _playback.position);
    if (!_danmakuOn) setState(() => _danmakuOn = true);
  }

  /// 放开 PopScope，否则随后的 popUntil 会被 canPop:false 拦住。
  Future<void> _releasePopGuard() async {
    if (!mounted) return;
    setState(() => _allowPop = true);
    await WidgetsBinding.instance.endOfFrame;
  }

  void _syncAndroidAutoPip() {
    final wantPip = _playerBackground == 'pip' && _playUrl.isNotEmpty;
    unawaited(MiniPlayerWindow.setAndroidAutoEnter(this, wantPip));
  }

  Future<void> _prepareQuit() async {
    await _stopHardAwait();
  }

  /// 离页硬停：soft pause → release → 清宿主 → 包装 dispose。
  /// 勿在此使用 [ref]：[_leavePage] 可能在 pop/dispose 之后仍调用本方法。
  /// [skipFlush]：离开页已落过进度时跳过二次 flush。
  Future<void> _stopHard({bool skipFlush = false}) async {
    if (!skipFlush) {
      try {
        await _flushWatchProgress(force: true);
      } catch (_) {}
    }
    _playbackLive = false;
    _advanceBusy = false;
    _playGen++;
    _endConsumedGen = _playGen;
    // 抬起播世代：返回/停播时丢弃进行中的 play/磁力 Fetch 结果
    _playAtSerial++;
    final stopSerial = _playAtSerial;
    _sessionStartedAt = null;
    _unwireEpisodeEnd();
    _posSub?.cancel();
    _unwirePlaybackNotify();
    _posSub = null;
    _magnetPlay = false;
    _stopBtProgressPoll();
    _syncAndroidAutoPip();
    // 离开详情：只软取消爬虫请求一次；不 stop thunder/source（起播路径再停）。
    final api = _api;
    if (api != null) {
      unawaited(api.cancelPending(hard: false, thunder: false));
    }

    // soft pause → release（FVP Surface：dispose 内先清 native 面再删 mdk）→ 清 _playUrl → dispose 包装类。
    final fvp = _fvp;
    final mk = _mk;
    final exo = _exo;
    final html = _html;
    final art = _art;
    final xg = _xg;
    final zw = _zw;
    final backends = <KotvPlayback?>[fvp, mk, exo, html, art, xg, zw];

    await kotvSoftPausePlayers(backends);
    await kotvHardReleasePlayers(backends, waitFirst: fvp);

    _fvp = null;
    _mk = null;
    _exo = null;
    _html = null;
    _art = null;
    _xg = null;
    _zw = null;
    _playUrl = '';
    _unbindWinInlineChrome();
    _lastVideoPaintRect = null;
    _videoLayerRect = null;
    _bodyClipRect = null;
    _holdImmersiveVideoGeom = false;
    if (mounted) {
      setState(() {});
      await WidgetsBinding.instance.endOfFrame;
    }

    kotvDisposePlaybackWrappers(backends);
    if (_mpvOpts.diskCache && !kotvIsAndroid()) {
      await kotvClearMpvDemuxerCacheDir();
    }

    if (stopSerial == _playAtSerial) _stoppedHard = true;
  }

  Future<void> _leavePage({VoidCallback? afterPop}) async {
    final inFlight = _leaveDone;
    if (_leaving || inFlight != null) {
      try {
        await (inFlight ?? _leaveDone)?.future.timeout(const Duration(seconds: 5));
      } catch (_) {}
      afterPop?.call();
      return;
    }
    final done = Completer<void>();
    _leaveDone = done;
    _leaving = true;
    // 立刻清 _active：否则 goKotvPage→prepareLeave 仍会 await 本页硬停，切 Tab 像点不动。
    if (_active == this) _active = null;
    _chromeCover.release(ref.read(detailChromeCoverProvider.notifier));
    try {
      // 进度/软停短超时不挡返回；先 pop，再 await 硬停。
      try {
        await _flushWatchProgress(force: true)
            .timeout(const Duration(milliseconds: 400));
      } catch (_) {}
      if (_immersiveFullscreen) {
        try {
          await _exitImmersiveFullscreen();
        } catch (_) {}
      }
      try {
        await kotvSoftPausePlayers(
          <KotvPlayback?>[_fvp, _mk, _exo, _html, _art, _xg, _zw],
        ).timeout(const Duration(milliseconds: 400));
      } catch (_) {}
      if (_miniDesktop) {
        try {
          await _exitMini();
        } catch (_) {}
      }
      if (!mounted) {
        await _stopHardAwait(skipFlush: true);
        afterPop?.call();
        return;
      }
      _allowPop = true;
      setState(() {});
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) {
        await _stopHardAwait(skipFlush: true);
        afterPop?.call();
        return;
      }
      Navigator.of(context).pop();
      afterPop?.call();
      await _stopHardAwait(skipFlush: true);
    } finally {
      if (!done.isCompleted) done.complete();
      if (_leaveDone == done) {
        _leaveDone = null;
      }
    }
  }

  /// 本集结束的两种方式：播完（completed），或无缝进入排好的下一集（queuedStart）。
  void _wireEpisodeEnd(KotvPlayback p) {
    _unwireEpisodeEnd();
    _endedSub = p.completedStream.listen((done) {
      if (!done || !mounted) return;
      unawaited(_onPlaybackEnded());
    });
    _queuedStartSub = p.queuedStartStream.listen(_onQueuedEpisodeStarted);
  }

  void _unwireEpisodeEnd() {
    _endedSub?.cancel();
    _queuedStartSub?.cancel();
    _endedSub = null;
    _queuedStartSub = null;
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
      if (_queuedEpisodeUnconfirmed && p.lastError != null) {
        _queuedEpisodeUnconfirmed = false;
        unawaited(_playAt(_epIdx));
        return;
      }
      _syncPlayStatus();
      final w = p.width;
      final h = p.height;
      final sizeChanged = w != _lastVideoW || h != _lastVideoH;
      if (sizeChanged) {
        _lastVideoW = w;
        _lastVideoH = h;
      }
      // Android 全屏换集黑盖：出尺寸或确认为纯音频后撤掉（纯音频永远无宽高，勿一直盖黑）。
      if (_immersiveEpCover && !kotvNeedsBlankSurfaceCover(p)) {
        setState(() => _immersiveEpCover = false);
        return;
      }
      // 原生 MPV：出尺寸后须 rebuild 才能按比例定视频层。
      if (sizeChanged && p is NativeMpvPlayback) {
        setState(() {});
        _syncWinInlineChrome();
        return;
      }
      _syncWinInlineChrome();
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
      _queuedEpisodeUnconfirmed = false;
    }
  }

  /// 无缝切到 [nextIdx]：已记账 / skipToNext 成功则 true（由 queuedStart 补账，勿 [_playAt]）。
  Future<bool> _takeSeamlessNext(int nextIdx) async {
    if (_epIdx == nextIdx) return true;
    if (_queuedNext?.idx != nextIdx) return false;
    if (!await _playback.skipToNext()) return _epIdx == nextIdx;
    // skip 已下令切入；enterQueued 可能同步或稍后经 playlist 回调，勿再硬切拆 Player。
    return true;
  }

  /// playbackEnded / onTimeChanged→nextEpisode / 控件下一集：每集只前进一次。
  /// [fromEnd] 为真时要求已 READY 且本世代未消耗；控件/手势下一集传 false。
  /// 全屏上滑已先做动画时由 [DetailFullscreenPage] 调 [onNext]，此处不再二次 animate。
  Future<void> _advanceToNextEpisode({bool fromEnd = true}) async {
    if (!mounted || _advanceBusy) return;
    if (fromEnd) {
      if (!_playbackLive) return;
      if (_endConsumedGen == _playGen) return;
    }
    final eps = _eps;
    final next = _epIdx + 1;
    if (next < 0 || next >= eps.length) {
      if (mounted) setState(() => _status = '播放结束');
      if (fromEnd) {
        _endConsumedGen = _playGen;
        _playbackLive = false;
      }
      return;
    }
    _endConsumedGen = _playGen;
    _playbackLive = false;
    _advanceBusy = true;
    try {
      _fsPageKey.currentState?.beginEpisodeSwitchQuiet();
      if (await _takeSeamlessNext(next)) return;
      if (mounted) setState(() => _status = fromEnd ? '自动播放下一集…' : '播放下一集…');
      // 仅自动连播需要跟手动画；手势/按钮已在全屏页内播过，勿再 animate。
      if (_immersiveFullscreen && fromEnd) {
        await _fsPageKey.currentState?.animateAutoNext();
      }
      if (!mounted) return;
      if (await _takeSeamlessNext(next)) return;
      await _playAt(next);
    } finally {
      _advanceBusy = false;
    }
  }

  /// 片头起播跳过；片尾 `ending+position>=duration` 切下一集；节流写续播进度。
  /// Clock 仅在 READY（[_playbackLive]）后生效，避免解析/换集中连跳。
  void _onPositionTick(Duration pos) {
    if (_playUrl.isEmpty || !mounted) return;
    _syncPlayStatus();
    _markPlaybackLiveIfNeeded();
    if (!_playbackLive || _endConsumedGen == _playGen) return;
    final dur = _playback.duration;
    _tickDurationMs = dur.inMilliseconds;
    if (!_nextPreloadRequested && dur.inMilliseconds > 0) {
      final endingMs = (_skipOpeningEnding && !_repeatOne) ? _endingSec * 1000 : 0;
      if (dur.inMilliseconds - endingMs - pos.inMilliseconds <= _nextEpisodeQueueLeadMs) {
        _nextPreloadRequested = true;
        _preloadNextEpisodeNow();
      }
    }
    if (dur.inMilliseconds > 0 && pos.inMilliseconds >= 5000) {
      final now = DateTime.now();
      if (_lastProgressSave == null || now.difference(_lastProgressSave!) >= const Duration(seconds: 5)) {
        _lastProgressSave = now;
        unawaited(_saveWatchProgress(pos.inMilliseconds, dur.inMilliseconds));
      }
    }
    if (!_skipOpeningEnding) return;
    if (_repeatOne) return;
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

  Future<void> _saveWatchProgress(int positionMs, int durationMs) async {
    await _writeWatchProgress(positionMs, durationMs, force: false);
  }

  /// 离开/换集：force 时忽略 5s 下限，立即把当前集进度写入 LocalHistory。
  Future<void> _flushWatchProgress({bool force = false}) async {
    final pos = _playback.position.inMilliseconds;
    final dur = _playback.duration.inMilliseconds;
    await _writeWatchProgress(pos, dur, force: force);
  }

  Future<void> _writeWatchProgress(int positionMs, int durationMs, {required bool force, String? episodeName}) async {
    final d = _detail;
    if (d == null) return;
    // 直播只记访问：不留续播点，下次从直播点开。
    final live = _playback.isLive;
    if (live) {
      positionMs = 0;
      durationMs = 0;
    } else {
      if (!force && positionMs < 5000) return;
      if (force && positionMs <= 0) return;
    }
    final epName = (episodeName ?? _currentEpisodeName() ?? '').trim();
    if (epName.isEmpty) return;
    final flagIdx = _playFlagIdx.clamp(0, d.flags.isEmpty ? 0 : d.flags.length - 1);
    final flag = d.flags.isEmpty ? '' : d.flags[flagIdx].flag;
    try {
      await LocalHistory.push(VodItem(
        id: _detailId(),
        name: d.name,
        pic: d.pic,
        site: _detailSite(),
        remarks: epName,
        flag: flag,
        configSource: _configSource,
        positionMs: positionMs,
        durationMs: durationMs,
      ));
      _lastProgressSave = DateTime.now();
    } catch (_) {}
  }

  /// 遥控与全屏设置里的「循环播放视频」都走这里；播放器自己循环，到片尾也不报完成。
  Future<void> _setRepeatOne(bool on) async {
    _repeatOne = on;
    // 单集循环不往下播：撤掉排好的下一集；关掉后到片尾前再排。
    _nextPreloadRequested = false;
    if (on && _queuedNext != null) {
      _queuedNext = null;
      await _playback.clearNext();
    }
    try {
      await _playback.setRepeatOne(on);
    } catch (_) {}
  }

  Future<void> _onPlaybackEnded() async {
    if (!mounted) return;
    if (_repeatOne) return;
    _markPlaybackLiveIfNeeded();
    if (!_playbackLive || _endConsumedGen == _playGen) return;
    final pos = _playback.position.inMilliseconds;
    final dur = _playback.duration.inMilliseconds;
    // 未知片长：坏 HLS/假 EOF 常见；勿当播完切集（直播走其它路径）。
    if (dur <= 0) return;
    // 黑屏/假结束：几乎没播过就不自动下一集
    if (pos < 8000) return;
    final nearEnd = pos + 8000 >= dur || pos >= (dur * 0.92).round();
    if (!nearEnd) return;
    await _advanceToNextEpisode();
  }

  final _chromeCover = KotvChromeCoverSession();

  @override
  void activate() {
    super.activate();
    _active = this;
    detailImmersiveBack = _handleImmersiveBack;
    _chromeCover.holdAfterFrame(context, () => mounted, () => ref.read(detailChromeCoverProvider.notifier));
  }

  @override
  void dispose() {
    // 勿在此处 ref.read：会抛 Bad state，打断后面的 FVP/播放器 stop。
    _unbindWinInlineChrome();
    WidgetsBinding.instance.removeObserver(this);
    _detachRemoteHandlers();
    kotvUnregisterQuitHook(_prepareQuit);
    if (_active == this) _active = null;
    if (detailImmersiveBack == _handleImmersiveBack) detailImmersiveBack = null;
    MiniPlayerWindow.onAndroidPipChanged = null;
    unawaited(MiniPlayerWindow.setAndroidAutoEnter(this, false));
    // 离开详情：回传扫码取消。软取消已在 [_stopHard] 做过；仅兜底未走 _leavePage 的路径。
    final api = _api;
    if (api != null) {
      unawaited(PostMsgHost.instance?.cancelAll(reply: true, popDialog: false) ?? Future<void>.value());
      if (!_stoppedHard) {
        unawaited(api.cancelPending(hard: false, thunder: false));
      }
    }
    if (_miniDesktop) {
      unawaited(MiniPlayerWindow.exit());
    }
    _unwireEpisodeEnd();
    _posSub?.cancel();
    _unwirePlaybackNotify();
    _stopBtProgressPoll();
    _danmakuItems.dispose();
    _fsSwipeDy.dispose();
    _winBuffer.dispose();
    _detailFocusArm.dispose();
    // 正常路径已在 [_stopHard] 里 await release+dispose，引擎引用已清空。
    // 异常路径：先调度 release（清 mdk），再摘引用；与 [_stopHard] 同序意图。
    if (!_stoppedHard) {
      final fvp = _fvp;
      final mk = _mk;
      final exo = _exo;
      final html = _html;
      final art = _art;
      final xg = _xg;
      final zw = _zw;
      final backends = <KotvPlayback?>[fvp, mk, exo, html, art, xg, zw];
      unawaited(() async {
        await kotvHardReleasePlayers(backends, waitFirst: fvp);
        kotvDisposePlaybackWrappers(backends);
      }());
      _fvp = null;
      _mk = null;
      _exo = null;
      _html = null;
      _art = null;
      _xg = null;
      _zw = null;
      _playUrl = '';
      _lastVideoPaintRect = null;
      _videoLayerRect = null;
      _bodyClipRect = null;
      _holdImmersiveVideoGeom = false;
    }
    super.dispose();
  }

  void _applyDetailSettings(Map<String, dynamic> settings) {
    final decode = '${settings['playerDecode'] ?? 'auto'}';
    if (decode.isNotEmpty) {
      _decodeMode = decode;
      _prefDecodeMode = decode;
    }
    _renderMode = kotvNormalizePlayerRender('${settings['playerRender'] ?? 'surface'}');
    _mpvOpts = KotvMpvOpts.fromSettings(settings, decodeMode: _decodeMode);
    _preloadNextEpisode = kotvSettingsFlag(settings['preloadNextEpisode']);
    _adFilterOn = kotvSettingsMapFlag(settings, 'adFilter', def: true);
    kotvPushPlayerSettings(
      settings,
      mpvOpts: _mpvOpts,
      current: _playback,
      mpv: _mk,
      exo: _exo,
      fvp: _fvp,
    );
    _playerBackground = kotvPlayerBackgroundFromSettings(settings);
    _holdSpeed = (double.tryParse('${settings['playerSpeedLongPress'] ?? '2.0'}') ?? 2.0).clamp(2.0, 5.0).toDouble();
    _ambientOn = _ambientFromSetting('${settings['playerAmbient'] ?? ''}');
    _stableVolumeOn = '${settings['playerStableVolume'] ?? ''}'.toLowerCase() == 'true';
    _syncAndroidAutoPip();
    _applyDanmakuPrefsFromSettings(settings, applyOffset: true);
    final scale = '${settings['playerScale'] ?? 'default'}';
    _aspect = kotvAspectFromScale(scale);
    unawaited(_playback.setVideoScale(_aspect.key));
    var playerVal = '${settings['player'] ?? kotvDefaultVodPlayer()}'.trim();
    if (playerVal.isEmpty) {
      playerVal = kotvDefaultVodPlayer();
    }
    _playerVal = kotvClampPlayerVal(playerVal, live: false);
    _prefPlayerVal = _playerVal;
    final failoverMode = '${settings['playerFailover'] ?? 'auto'}'.trim().toLowerCase();
    _prefPlayerFailover = (failoverMode == 'off' || failoverMode == 'false') ? 'off' : 'auto';
    _prefSpeed = double.tryParse('${settings['playerSpeed'] ?? ''}');
    _skipOpeningEnding = kotvSettingsMapFlag(settings, 'playerSkipOpeningEnding', def: true);
    _prefVolume = _normalizePlayerVolumePref(settings['playerVolume']);
    if (_prefVolume == 80) {
      final rawVol = double.tryParse('${settings['playerVolume'] ?? ''}');
      if (rawVol != null && rawVol <= 0) {
        unawaited(KotvSettingsCache.set(ref.read(apiProvider), 'playerVolume', '80'));
      }
    }
    kotvApplyPlayUaSetting('${settings['ua'] ?? ''}');
    unawaited(KotvBufferBudget.warm());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      Object? fetchError;
      Map<String, dynamic>? fetched;
      try {
        fetched = await ref.read(apiProvider).detail(id: _routeId, site: _routeSite);
      } catch (e) {
        fetchError = e;
      }
      // jar 在 detailContent 里 finish 了详情层：本页出栈回列表；首页由 openVodItem 在 push 返回后刷新。
      if (await kotvConsumeJarDetailDismissed()) {
        if (mounted) await _leavePage();
        return;
      }
      if (fetchError != null) {
        if (await _switchEmptyDetail(_routeTitle)) return;
        throw fetchError;
      }
      if (!mounted) return;
      final data = fetched!;
      final vod = VodDetail.fromJson(Map<String, dynamic>.from(data['vod'] as Map));
      if (vod.flags.isEmpty) {
        final name = _routeTitle.trim().isNotEmpty ? _routeTitle.trim() : vod.name.trim();
        if (await _switchEmptyDetail(name)) return;
      }
      _detailMagnet = data['magnet'] == true;
      _detailExpand = data['expand'] == true;
      final id = vod.id.isNotEmpty ? vod.id : _routeId;
      final site = vod.site.isNotEmpty ? vod.site : _routeSite;
      final entry = _routeTitle.trim();
      final apiName = vod.name.trim();
      final displayName = apiName.isNotEmpty ? apiName : entry;
      final named = displayName.isNotEmpty && displayName != apiName
          ? vod.withMeta(name: displayName)
          : vod;
      final cachedSettings = KotvSettingsCache.peek();
      if (cachedSettings.isNotEmpty) {
        _applyDetailSettings(cachedSettings);
      }
      if (!mounted) return;
      setState(() {
        _detail = named;
        if (displayName.isNotEmpty) _routeTitle = displayName;
        _loading = false;
      });
      var configSource = _configSource;
      final cachedCfg = ref.read(configProvider).valueOrNull;
      if (cachedCfg != null) {
        configSource = '${cachedCfg['source'] ?? ''}'.trim();
      } else {
        try {
          final cfg = await ref.read(apiProvider).getConfig();
          configSource = '${cfg['source'] ?? ''}'.trim();
        } catch (_) {}
      }
      if (!mounted) return;
      _configSource = configSource;
      if (vod.id.isNotEmpty && _routeId.isNotEmpty && vod.id != _routeId) {
        await LocalCollect.replaceId(
          site: site,
          oldId: _routeId,
          newId: vod.id,
          configSource: configSource,
        );
        await LocalHistory.replaceId(site: site, oldId: _routeId, newId: vod.id);
      }
      await LocalCollect.updateMeta(
        id: id,
        site: site,
        configSource: configSource,
        name: named.name,
        pic: named.pic,
        remarks: named.remarks,
        typeName: named.typeName,
      );
      final kept = await LocalCollect.isKept(id, site, configSource: configSource);
      final rev = await LocalRevSort.get(id, site);
      if (!mounted) return;
      if (KotvSettingsCache.peek().isEmpty) {
        try {
          final settings = await KotvSettingsCache.fetch(ref.read(apiProvider));
          if (mounted && settings.isNotEmpty) _applyDetailSettings(settings);
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _kept = kept;
        _reversed = rev;
      });
      final off = await LocalPlayOffsets.get(id, site);
      if (mounted) {
        setState(() {
          _openingSec = off.$1;
          _endingSec = off.$2;
        });
      }
      if (!mounted) return;
      final needExpand = _detailExpand;
      if (needExpand) {
        // 先展开再起播，避免异步 expand 与 _playAt 竞态清空选集。
        await _expandDetail(id: id, site: site);
        if (mounted) await _resumeOrAutoPlay();
      } else {
        unawaited(_resumeOrAutoPlay());
      }
    } catch (e) {
      if (!mounted) return;
      if (kotvMessageNeedsLogin(e)) {
        setState(() => _loading = false);
        final ok = await kotvPresentLoginIfNeeded(context, ref);
        if (ok && mounted) await _load();
        return;
      }
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _expandDetail({required String id, required String site}) async {
    if (!mounted) return;
    final cur = _detail;
    if (cur == null) return;
    // 已在播非磁力：展开只更新列表，不抢状态栏、不清选集
    final playingNonMagnet = _playUrl.isNotEmpty && !_magnetPlay;
    final magnet = _detailMagnet;
    if (!playingNonMagnet) {
      setState(() => _status = magnet ? '正在展开磁力文件…' : '正在展开播放列表…');
    }
    if (magnet) _startBtProgressPoll(expanding: true);
    try {
      // 空 url 契约下客户端 flags 无原始链：引擎用详情缓存展开。
      final data = await ref.read(apiProvider).detailExpand(id: id, site: site, flags: const []);
      if (!mounted) return;
      if (data['expanded'] == true && data['vod'] is Map) {
        final expanded = VodDetail.fromJson(Map<String, dynamic>.from(data['vod'] as Map));
        _detailMagnet = data['magnet'] == true;
        _detailExpand = data['expand'] == true;
        // 只替换线路/剧集，保留当前详情其它字段，避免整页重建冲掉扫码等弹窗。
        setState(() {
          _detail = cur.withFlags(expanded.flags);
          if (_flagIdx >= expanded.flags.length) _flagIdx = 0;
          _epPage = 0;
          if (!playingNonMagnet && _epIdx >= 0) _epIdx = -1;
          if (!playingNonMagnet) {
            _status = magnet ? '磁力文件已展开，可选集播放' : '播放列表已展开，可选集播放';
          }
        });
      } else if (mounted && !playingNonMagnet) {
        setState(() => _status = '选择剧集开始播放');
      }
    } catch (e) {
      if (mounted && !playingNonMagnet) {
        setState(() => _status = magnet ? '磁力展开失败，仍可点原链起播' : '播放列表展开失败，仍可点原链起播');
      }
    } finally {
      if (magnet) _stopBtProgressPoll();
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

  void _clearResumeSeek() {
    _resumeSeekMs = 0;
    _resumeSeekRemarks = '';
    _resumeSeekFlag = '';
  }

  /// 详情就绪后起播：folder mark 优先，否则按历史线路+集名，再否则第一线第一集。
  Future<void> _resumeOrAutoPlay() async {
    final d = _detail;
    if (d == null || d.flags.isEmpty) return;

    var mark = _routeMark.trim();
    var histFlag = '';
    _clearResumeSeek();
    if (mark.isEmpty) {
      try {
        final id = _detailId();
        final site = _detailSite();
        final hist = await LocalHistory.list();
        for (final h in hist) {
          if (h.id == id && h.site == site) {
            mark = h.remarks.trim();
            histFlag = h.flag.trim();
            if (h.positionMs > 0) {
              _resumeSeekMs = h.positionMs;
              _resumeSeekRemarks = mark;
              _resumeSeekFlag = histFlag;
            }
            break;
          }
        }
      } catch (_) {}
    }
    if (!mounted) return;
    var nextFlag = _flagIdx;
    if (histFlag.isNotEmpty) {
      final fi = d.flags.indexWhere((f) => f.flag == histFlag || f.show == histFlag);
      if (fi >= 0) nextFlag = fi;
    }
    _flagIdx = nextFlag; // _eps 依赖当前线路
    final eps = _eps;
    if (eps.isEmpty) return;
    var idx = mark.isNotEmpty ? _matchEpisodeIndex(eps, mark) : -1;
    if (idx < 0) {
      idx = 0;
      _clearResumeSeek(); // 未命中历史集则不续播进度
    }
    if (!mounted) return;
    setState(() {
      _flagIdx = nextFlag;
      _epIdx = idx;
      _epPage = idx ~/ _epSize;
    });
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

  Future<void> _applyStableVolume(KotvPlayback p, bool on) async {
    await p.setStableVolume(on);
  }

  Future<void> _searchAssrtSubtitle() async {
    final d = _detail;
    final initial = (d?.name ?? '').trim();
    final qCtrl = TextEditingController(text: initial);
    final p = KotvPalette.of(context);
    final query = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.dialogBg,
        title: Text('Assrt 搜索字幕', style: TextStyle(color: p.fg, fontWeight: FontWeight.w700)),
        content: KotvTvTextField(
          controller: qCtrl,
          autofocus: true,
          style: TextStyle(color: p.fg),
          decoration: InputDecoration(
            hintText: '片名 / 关键词',
            hintStyle: TextStyle(color: p.muted),
            filled: true,
            fillColor: p.input,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          KotvFocusAction(label: '取消', color: p.muted, onPressed: () => Navigator.pop(ctx)),
          KotvFocusAction(label: '搜索', filled: true, onPressed: () => Navigator.pop(ctx, qCtrl.text.trim())),
        ],
      ),
    );
    qCtrl.dispose();
    if (query == null || query.length < 2 || !mounted) return;
    try {
      final res = await ref.read(apiProvider).assrtSearch(query);
      final items = (res['items'] as List?) ?? const [];
      if (!mounted) return;
      if (items.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('未找到字幕')));
        return;
      }
      final picked = await showModalBottomSheet<Map<String, dynamic>>(
        context: context,
        backgroundColor: Colors.black87,
        builder: (ctx) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final raw in items)
                if (raw is Map)
                  ListTile(
                    title: Text('${raw['title'] ?? ''}', style: const TextStyle(color: Colors.white)),
                    onTap: () => Navigator.pop(ctx, Map<String, dynamic>.from(raw)),
                  ),
            ],
          ),
        ),
      );
      if (picked == null || !mounted) return;
      final id = (picked['id'] as num?)?.toInt() ?? 0;
      if (id <= 0) return;
      final detail = await ref.read(apiProvider).assrtDetail(id);
      final files = (detail['files'] as List?) ?? const [];
      if (!mounted) return;
      if (files.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('该条目无可下载字幕')));
        return;
      }
      Map<String, dynamic> file = Map<String, dynamic>.from(files.first as Map);
      if (files.length > 1) {
        final f = await showModalBottomSheet<Map<String, dynamic>>(
          context: context,
          backgroundColor: Colors.black87,
          builder: (ctx) => SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final raw in files)
                  if (raw is Map)
                    ListTile(
                      title: Text('${raw['name'] ?? raw['url']}', style: const TextStyle(color: Colors.white)),
                      onTap: () => Navigator.pop(ctx, Map<String, dynamic>.from(raw)),
                    ),
              ],
            ),
          ),
        );
        if (f == null || !mounted) return;
        file = f;
      }
      final dl = await ref.read(apiProvider).assrtDownload(
            url: '${file['url'] ?? ''}',
            name: '${file['name'] ?? ''}',
            size: '${file['size'] ?? ''}',
          );
      final path = '${dl['path'] ?? ''}'.trim();
      if (path.isEmpty || !mounted) return;
      await _playback.addSubtitleFile(path, title: '${file['name'] ?? 'Assrt'}');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已加载字幕：${file['name'] ?? path}')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  String _playCacheKey(String flag, int index) => '$flag|$index';

  void _trimPlayCache() {
    if (_nextPlayCache.length <= 2) return;
    final keys = _nextPlayCache.keys.toList();
    for (final k in keys.take(_nextPlayCache.length - 2)) {
      _nextPlayCache.remove(k);
    }
  }

  /// 离片尾（扣掉片尾跳过）还有这么久时解析下一集并排进当前播放器，本集播完前缓冲好它。
  /// 不在开播时就解析：带时效的地址等到播完可能已经过期。
  static const _nextEpisodeQueueLeadMs = 180000;

  /// 「预加载下一集」：解析下一集并排进当前播放器的播放列表，播完无缝接上。
  /// Exo、MPV 支持；FVP / 网页排不上。
  /// 排不上（磁力、DRM、碟片、请求头与本集不同等）时留下解析结果，换集时少等一次解析。
  void _preloadNextEpisodeNow() {
    final pb = _playback;
    final playerVal = _playerVal;
    final d = _detail;
    if (!_preloadNextEpisode || _repeatOne || d == null || d.flags.isEmpty) return;
    final flag = d.flags[_flagIdx.clamp(0, d.flags.length - 1)].flag;
    final eps = _eps;
    final nextIdx = _epIdx + 1;
    if (nextIdx <= 0 || nextIdx >= eps.length) return;
    final nextEp = eps[nextIdx];
    final key = _playCacheKey(flag, nextIdx);
    final serial = _playAtSerial;
    final token = ++_nextPreloadSerial;
    bool stale() => !mounted || token != _nextPreloadSerial || serial != _playAtSerial || !identical(_playback, pb);
    unawaited(() async {
      try {
        final data = _nextPlayCache[key] ??
            (_episodeCanDirectPlay(nextEp.url)
                ? <String, dynamic>{
                    'url': nextEp.url.trim(),
                    if (nextEp.headers != null) 'headers': nextEp.headers,
                    'magnet': false,
                  }
                : await ref.read(apiProvider).play(
                      url: '',
                      index: nextIdx,
                      site: _detailSite(),
                      id: _detailId(),
                      flag: flag,
                    ));
        if (stale()) return;
        final base = ref.read(apiProvider).baseUrl;
        final playUrl = kotvRewriteEngineLocalUrl('${data['url'] ?? ''}', base);
        if (playUrl.isEmpty || data['magnet'] == true || playUrl.contains('/proxy/bt/')) return;
        _nextPlayCache[key] = Map<String, dynamic>.from(data);
        _trimPlayCache();
        final drm = data['drm'];
        if (drm is Map && '${drm['type'] ?? ''}'.trim().isNotEmpty) return;
        final rawHeaders = _playHeadersOf(data);
        final format = _playFormatOf(data);
        final target = _openTargetOf(
          playerVal: playerVal,
          playUrl: playUrl,
          mediaUrl: kotvRewriteEngineLocalUrl('${data['media'] ?? ''}', base),
          directUrl: kotvRewriteEngineLocalUrl('${data['direct'] ?? ''}', base),
          rawHeaders: rawHeaders,
          magnet: false,
          format: format,
          adFilterOn: _adFilterOn,
        );
        if (KotvDiscPlay.looksLikeAny([target.url, nextEp.url])) return;
        final queued = await pb.queueNext(
          id: key,
          url: target.url,
          headers: target.headers,
          format: format,
          subs: _playSubsOf(data),
          startAt: _queueOpeningStartAt(),
        );
        if (!queued || stale()) return;
        _queuedNext = (key: key, idx: nextIdx, playUrl: playUrl, headers: rawHeaders, data: Map<String, dynamic>.from(data));
      } catch (_) {}
    }());
  }

  /// 无缝排队用的片头起点；写入各引擎 queueNext(startAt)，切入时由列表项自身定位。
  Duration _queueOpeningStartAt() {
    if (!_skipOpeningEnding || _openingSec <= 0) return Duration.zero;
    return Duration(seconds: _openingSec);
  }

  /// 播放器已无缝播到排好的下一集：只做换集的记账（进度、选集、历史、弹幕、遥控上报），不停播、不重开。
  void _onQueuedEpisodeStarted(String key) {
    final q = _queuedNext;
    final d = _detail;
    if (!mounted || q == null || q.key != key || d == null || q.idx >= _eps.length) return;
    // 沉浸挡亮栏；_playbackLive=false 挡住旧集 completed。新集是新 playGen，勿写 endConsumed。
    _fsPageKey.currentState?.beginEpisodeSwitchQuiet();
    _queuedNext = null;
    _nextPlayCache.remove(q.key);
    final prevName = _currentEpisodeName() ?? '';
    if (prevName.isNotEmpty && _tickDurationMs > 0) {
      unawaited(_writeWatchProgress(_tickDurationMs, _tickDurationMs, force: true, episodeName: prevName));
    }
    final ep = _eps[q.idx];
    _playGen++;
    final serial = ++_playAtSerial;
    _playbackLive = false;
    _sessionStartedAt = DateTime.now();
    _nextPreloadRequested = false;
    _tickDurationMs = 0;
    _queuedEpisodeUnconfirmed = true;
    // 片头已写入 queueNext(startAt)；此处勿再 seek，避免 keep-open/EOF 切集窗口打到旧文件。
    _openingSeekDone = true;
    _playHeaders = q.headers;
    _danmakuItems.value = const [];
    _spiderDanmakuSources = kotvDanmakuSourcesFrom(q.data['danmaku']);
    _nodeDanmuPushUrl = null;
    setState(() {
      _epIdx = q.idx;
      _epPage = q.idx ~/ _epSize;
      _playUrl = q.playUrl;
    });
    _applySourceMeta(q.data);
    _syncFullscreen();
    _syncPlayStatus();
    _touchEpisodeHistory(ep.name, d.flags[_flagIdx.clamp(0, d.flags.length - 1)].flag);
    unawaited(_loadDanmakuForEpisode(name: d.name, episode: ep.name, playSerial: serial));
    ref.read(remoteBridgeProvider)?.reportMedia(state: 'playing', title: '${d.name} · ${ep.name}', url: q.playUrl);
  }

  /// 只记当前集，同集保留续播进度（勿 push positionMs:0）。
  void _touchEpisodeHistory(String episodeName, String flag) {
    final d = _detail;
    if (d == null) return;
    unawaited(LocalHistory.touchEpisode(
      id: _detailId(),
      name: d.name,
      pic: d.pic,
      site: _detailSite(),
      remarks: episodeName,
      flag: flag,
      typeName: d.typeName,
      configSource: _configSource,
    ));
  }

  /// 专用源可带回封面/简介；片名仅当前为空时补全，勿用 play.title（曾默认=vodID）覆盖已有名。
  void _applySourceMeta(Map<String, dynamic> data) {
    final srcTitle = '${data['title'] ?? ''}'.trim();
    final srcArt = '${data['artwork'] ?? ''}'.trim();
    final srcDesc = '${data['desc'] ?? ''}'.trim();
    if (!mounted || _detail == null || (srcTitle.isEmpty && srcArt.isEmpty && srcDesc.isEmpty)) return;
    final curName = _detail!.name.trim();
    setState(() {
      _detail = _detail!.withMeta(
        name: (curName.isEmpty && srcTitle.isNotEmpty) ? srcTitle : null,
        pic: srcArt.isNotEmpty ? srcArt : null,
        content: srcDesc.isNotEmpty ? srcDesc : null,
      );
      if (curName.isEmpty && srcTitle.isNotEmpty) {
        _routeTitle = srcTitle;
      }
    });
  }

  /// 播放回包里的请求头（去掉空键空值）。
  static Map<String, String> _playHeadersOf(Map<String, dynamic> data) => {
        for (final e in Map<String, dynamic>.from((data['headers'] as Map?) ?? const {}).entries)
          if (e.key.trim().isNotEmpty && '${e.value}'.trim().isNotEmpty) e.key: '${e.value}',
      };

  static String? _playFormatOf(Map<String, dynamic> data) {
    final f = '${data['format'] ?? ''}'.trim();
    return f.isEmpty ? null : f;
  }

  /// 播放回包里的外挂字幕；Exo 要在 open 前写进 MediaItem。
  static List<Map<String, dynamic>> _playSubsOf(Map<String, dynamic> data) {
    final raw = data['subs'];
    return [
      if (raw is List)
        for (final s in raw)
          if (s is Map)
            {
              'url': '${s['url'] ?? ''}',
              'name': '${s['name'] ?? ''}',
              'lang': '${s['lang'] ?? ''}',
              'format': '${s['format'] ?? ''}',
            },
    ];
  }

  /// 交给内置播放器打开的地址与请求头：本地文件直接开；其余走 [kotvResolvePreferredPlayOpen]。
  ({String url, Map<String, String>? headers}) _openTargetOf({
    required String playerVal,
    required String playUrl,
    required String mediaUrl,
    required String directUrl,
    required Map<String, String> rawHeaders,
    required bool magnet,
    String? format,
    bool adFilterOn = true,
    bool forceProxy = false,
  }) {
    final localMedia = mediaUrl.startsWith('file:') ||
        mediaUrl.startsWith('content:') ||
        (mediaUrl.startsWith('/') && !mediaUrl.contains('://'));
    if (!magnet && localMedia) return (url: mediaUrl, headers: null);
    return kotvResolvePreferredPlayOpen(
      playerVal: playerVal,
      playUrl: playUrl,
      directUrl: directUrl,
      rawHeaders: rawHeaders,
      magnet: magnet,
      format: format,
      adFilterOn: adFilterOn,
      forceProxy: forceProxy,
    );
  }

  /// 起播或改了弹幕设置：引擎按设置把片源弹幕和自动搜到的合成源列表，再加载默认选中的那条。
  Future<void> _loadDanmakuForEpisode({
    required String name,
    required String episode,
    int? playSerial,
  }) async {
    final serial = playSerial ?? _playAtSerial;
    var pushUrl = (_nodeDanmuPushUrl ?? '').trim();
    if (pushUrl.isNotEmpty) {
      _ensureDanmakuPushSource(pushUrl);
    } else {
      _danmakuItems.value = const [];
    }
    try {
      final res = await ref.read(apiProvider).danmakuAuto(
            site: _detailSite(),
            name: name,
            episode: episode,
            sources: [for (final s in _spiderDanmakuSources) s.toJson()],
          );
      if (!mounted || serial != _playAtSerial) return;
      // await 期间可能刚到 danmuPush：再读一次，避免二次拉取覆盖推送轨。
      pushUrl = (_nodeDanmuPushUrl ?? '').trim();
      final keepPush = pushUrl.isNotEmpty;
      if (keepPush) _ensureDanmakuPushSource(pushUrl);
      var sources = kotvDanmakuSourcesFrom(res['sources']);
      if (pushUrl.isNotEmpty && !sources.any((s) => s.url == pushUrl)) {
        sources = [DanmakuSource(name: '推送', url: pushUrl), ...sources];
      }
      var selected = (res['selected'] as num?)?.toInt() ?? 0;
      if (pushUrl.isNotEmpty) {
        final pi = sources.indexWhere((s) => s.url == pushUrl);
        if (pi >= 0) selected = pi;
      }
      setState(() {
        _danmakuSources = sources;
        _danmakuSourceIdx =
            sources.isEmpty ? 0 : selected.clamp(0, sources.length - 1);
      });
      if (keepPush) return;
      if (sources.isNotEmpty) {
        await _loadDanmakuSource(_danmakuSourceIdx, playSerial: serial);
      }
    } catch (_) {
      if (!mounted || serial != _playAtSerial) return;
      if ((_nodeDanmuPushUrl ?? '').trim().isEmpty) {
        setState(() => _danmakuSources = const []);
      }
    }
  }

  /// 加载弹幕源列表里第 [index] 条。[notify]：用户手动选的源，失败或为空时提示。
  Future<void> _loadDanmakuSource(int index, {int? playSerial, bool notify = false}) async {
    final serial = playSerial ?? _playAtSerial;
    if (index < 0 || index >= _danmakuSources.length) return;
    final items = await _fetchDanmaku(_danmakuSources[index].url, notify: notify);
    if (!mounted || serial != _playAtSerial) return;
    _danmakuItems.value = items ?? const [];
  }

  /// 引擎拉取并解析一个弹幕源，套上当前时轴偏移；失败返回 null。
  Future<List<DanmakuItem>?> _fetchDanmaku(String url, {bool notify = false}) async {
    void tell(String msg) {
      if (notify && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }

    try {
      final res = await ref.read(apiProvider).danmakuLoad(
            url,
            duration: _existingPlayback?.duration ?? Duration.zero,
          );
      final items = kotvShiftDanmaku(kotvDanmakuItemsFrom(res['items']), _danmakuOffsetSec);
      tell(items.isEmpty ? '这个弹幕源没有弹幕' : '已加载 ${items.length} 条弹幕');
      return items;
    } catch (e) {
      tell('弹幕加载失败：$e');
      return null;
    }
  }

  void _reloadDanmakuForCurrentEpisode() {
    final d = _detail;
    if (d == null || _epIdx < 0 || _epIdx >= _eps.length) return;
    unawaited(_loadDanmakuForEpisode(name: d.name, episode: _eps[_epIdx].name));
  }

  /// 「搜索弹幕」：选中的源不在列表里就放到第一位，然后加载它。
  Future<void> _searchDanmaku() async {
    final d = _detail;
    if (d == null) return;
    final episode = (_epIdx >= 0 && _epIdx < _eps.length) ? _eps[_epIdx].name : '';
    // Win7：原生播控挂起，Flutter 弹窗才不会被分层播控窗盖住。
    final picked = await KotvWinChrome.withSuspended(
      () => showKotvDanmakuSearchDialog(
        context,
        api: ref.read(apiProvider),
        name: d.name,
        episode: episode,
      ),
    );
    if (picked == null || !mounted) return;
    var idx = _danmakuSources.indexWhere((s) => s.url == picked.url);
    setState(() {
      if (idx < 0) {
        _danmakuSources = [picked, ..._danmakuSources];
        idx = 0;
      }
      _danmakuSourceIdx = idx;
      _danmakuOn = true;
    });
    await _loadDanmakuSource(idx, notify: true);
  }

  /// 选集：未在播则起播；已选中再点则进全屏（遥控少一步）。
  Future<void> _onEpisodeTap(int epIdx, {bool fullscreen = false}) async {
    if (_leaving) return;
    if (epIdx == _epIdx && _playUrl.isNotEmpty && _playbackLive) {
      if (!_immersiveFullscreen) await _enterFullscreen();
      return;
    }
    await _playAt(epIdx, fullscreen: fullscreen);
  }

  /// 本客户端能否跳过 play、直接喂 [url]。
  /// content: 可直喂；http(s) 等带 scheme 可直喂；file: 与无 scheme 本机路径仅本机引擎可直喂，
  /// 远端须走 play 换成 /file/。
  bool _episodeCanDirectPlay(String url) {
    final u = url.trim();
    if (u.isEmpty) return false;
    final low = u.toLowerCase();
    if (low.startsWith('content:')) return true;
    final localEngine = kotvIsLocalEngineBaseUrl(ref.read(apiProvider).baseUrl);
    if (low.startsWith('file:')) return localEngine;
    if (u.contains('://')) return true;
    // 无 scheme：绝对路径 / Windows 盘符等本机文件。
    return localEngine;
  }

  Future<void> _playAt(int epIdx, {bool fullscreen = false}) async {
    if (_leaving || !mounted) return;
    final d = _detail;
    if (d == null || d.flags.isEmpty) return;
    final flag = d.flags[_flagIdx.clamp(0, d.flags.length - 1)];
    final eps = _eps;
    if (epIdx < 0 || epIdx >= eps.length) return;
    final ep = eps[epIdx];
    _playFlagIdx = _flagIdx;
    final prevEpIdx = _epIdx;
    final prevEpName = (prevEpIdx >= 0 && prevEpIdx != epIdx) ? (_currentEpisodeName() ?? '') : '';
    final flushPos = prevEpName.isNotEmpty ? _playback.position.inMilliseconds : 0;
    final flushDur = prevEpName.isNotEmpty ? _playback.duration.inMilliseconds : 0;
    _stoppedHard = false;
    // 换集：抬世代，关掉 READY/连播（BUFFERING 时 Clock=null）
    final gen = ++_playGen;
    final serial = ++_playAtSerial;
    _playbackLive = false;
    _sessionStartedAt = null;
    _lastVideoW = 0;
    _lastVideoH = 0;
    _openingSeekDone = false;
    _nextPreloadRequested = false;
    _queuedNext = null;
    _queuedEpisodeUnconfirmed = false;
    _tickDurationMs = 0;
    _unwireEpisodeEnd();
    _posSub?.cancel();
    _posSub = null;
    _danmakuItems.value = const [];
    _spiderDanmakuSources = const [];
    _nodeDanmuPushUrl = null;
    final canDirect = _episodeCanDirectPlay(ep.url);
    // 立刻高亮：先于 flush/停播，避免点选集要等落盘才变色。
    if (mounted) {
      setState(() {
        _epIdx = epIdx;
        _epPage = epIdx ~/ _epSize;
        _magnetPlay = false;
        // Android Hybrid：全屏换集先盖黑，避免 Surface 镂空透出详情；桌面 Texture 不盖。
        if (kotvIsAndroid() && _immersiveFullscreen) _immersiveEpCover = true;
        // 可直开跳过 play；本机路径在远端须走 play 换成 /file/。
        _status = canDirect ? '换集中…' : (_detailMagnet ? '磁力解析中…' : '解析中…');
      });
    }
    _syncFullscreen();
    // 换集前落盘上一集进度（高亮已切到新集，须用记下的集名）。
    if (prevEpName.isNotEmpty) {
      try {
        await _writeWatchProgress(flushPos, flushDur, force: true, episodeName: prevEpName);
      } catch (_) {}
    }
    // 硬切：[_stopAllBackends]（pause→卸文件），桌面 MPV 实例保留；无缝不进 [_playAt]。
    await _stopAllBackends();
    if (serial != _playAtSerial || !mounted) return;
    // 先 await 软取消上一集（Java / Python·JS / Node），再 play。
    // unawaited 会与本次 play 竞态；软取消未结束就开新解析时，脚本可能报「已中断」。
    await ref.read(apiProvider).cancelPending(
          hard: false,
          thunder: !canDirect && _detailMagnet,
        );
    if (serial != _playAtSerial || !mounted) return;
    _syncAndroidAutoPip();
    _syncFullscreen();
    if (!canDirect && _detailMagnet) _startBtProgressPoll();
    // 与 play 解析并行：只记当前集，同集保留续播进度（勿 push positionMs:0）。
    _touchEpisodeHistory(ep.name, flag.flag);
    try {
      Map<String, dynamic> data;
      final cacheKey = _playCacheKey(flag.flag, epIdx);
      final cached = _nextPlayCache.remove(cacheKey);
      Future<Map<String, dynamic>> fetchPlay() async {
        if (canDirect) {
          return {
            'url': ep.url.trim(),
            'headers': ep.headers ?? const <String, String>{},
            'magnet': false,
            'parsed': false,
          };
        }
        return ref.read(apiProvider).play(
              url: '',
              index: epIdx,
              site: _detailSite(),
              id: _detailId(),
              flag: flag.flag,
            );
      }

      try {
        if (cached != null && '${cached['url'] ?? ''}'.trim().isNotEmpty) {
          data = cached;
        } else {
          data = await fetchPlay();
        }
      } catch (e) {
        // 从后台回来常见引擎僵死：Connection closed / refused。先拉起再重试一次。
        if (!_isLocalEngineConnError(e)) rethrow;
        final ok = await ref.read(engineLauncherProvider).recoverIfNeeded();
        if (!ok || serial != _playAtSerial || !mounted) rethrow;
        data = await fetchPlay();
      }
      if (serial != _playAtSerial || !mounted) return;
      final apiBase = ref.read(apiProvider).baseUrl;
      var playUrl = kotvRewriteEngineLocalUrl(
        '${data['url'] ?? ''}',
        apiBase,
      );
      if (playUrl.isEmpty) {
        // 空地址留在详情；Config 弹窗依赖 pause 仍保留的 Activity，勿出栈。
        // 无 msg：多为 Config 副作用，不标「加载失败」。
        // 上一集已卸文件。清舞台 URL，避免集号新、地址旧。
        final tip = '${data['msg'] ?? ''}'.trim();
        if (!mounted) return;
        if (kotvMessageNeedsLogin(tip)) {
          final ok = await kotvPresentLoginIfNeeded(context, ref);
          if (ok && mounted && serial == _playAtSerial) {
            unawaited(_playAt(epIdx, fullscreen: fullscreen));
          }
          return;
        }
        _clearResumeSeek();
        setState(() {
          _playUrl = '';
          _status = tip;
          _immersiveEpCover = false;
        });
        _unbindWinInlineChrome();
        _stopBtProgressPoll();
        _playbackLive = false;
        _sessionStartedAt = null;
        return;
      }
      final mediaUrl = kotvRewriteEngineLocalUrl(
        '${data['media'] ?? ''}',
        apiBase,
      );
      var directUrl = kotvRewriteEngineLocalUrl(
        '${data['direct'] ?? ''}',
        apiBase,
      );
      var rawHeaders = _playHeadersOf(data);
      _playHeaders = rawHeaders;
      final magnet = data['magnet'] == true || playUrl.contains('/proxy/bt/');
      _magnetPlay = magnet;
      if (magnet) _startBtProgressPoll();
      final drmRaw = data['drm'];
      final drm = drmRaw is Map
          ? Map<String, dynamic>.from(drmRaw)
          : null;
      final hasDrm = drm != null && '${drm['type'] ?? ''}'.trim().isNotEmpty;
      var playSettings = <String, dynamic>{};
      try {
        playSettings = await KotvSettingsCache.fetch(ref.read(apiProvider));
      } catch (_) {}
      if (playSettings.isNotEmpty) {
        kotvApplyPlayUaSetting('${playSettings['ua'] ?? ''}');
        final fo = '${playSettings['playerFailover'] ?? ''}'.trim();
        if (fo.isNotEmpty) {
          _prefPlayerFailover = KotvPlaybackFailover.enabledFromSetting(fo) ? 'auto' : 'off';
        }
        final pv = '${playSettings['player'] ?? ''}'.trim();
        if (pv.isNotEmpty) {
          _prefPlayerVal = kotvClampPlayerVal(pv, live: false);
        }
        final decode = '${playSettings['playerDecode'] ?? ''}'.trim();
        if (decode.isNotEmpty) {
          _prefDecodeMode = decode;
        }
        _renderMode = kotvNormalizePlayerRender('${playSettings['playerRender'] ?? _renderMode}');
        final speedPref = double.tryParse('${playSettings['playerSpeed'] ?? ''}');
        if (speedPref != null && speedPref > 0) {
          _prefSpeed = kotvClampPlayRate(speedPref);
        }
        final volPref = _normalizePlayerVolumePref(playSettings['playerVolume']);
        if (volPref != null) {
          _prefVolume = volPref;
        }
        _preloadNextEpisode = kotvSettingsFlag(playSettings['preloadNextEpisode']);
        _adFilterOn = kotvSettingsMapFlag(playSettings, 'adFilter', def: true);
        _exo?.applyPlayerOptions(playSettings);
        _fvp?.applyPlayerOptions(playSettings);
      }
      // 每次 failover 新建 Exo/FVP 时用这份，避免仍按进页默认 surface create（ADB: FVP→Exo render=surface）。
      final renderMode = kotvNormalizePlayerRender(_renderMode);
      _renderMode = renderMode;
      // 有 DRM 或 SMB 强制 Exo；碟片/ISO 强制 MPV（dvdnav/libbluray 或 force-iso）。
      final smb = mediaUrl.trim().toLowerCase().startsWith('smb://') ||
          playUrl.trim().toLowerCase().startsWith('smb://');
      final discHint = KotvDiscPlay.looksLikeAny([mediaUrl, playUrl, ep.url]);
      final String startPlayer;
      if ((hasDrm || smb) && kotvIsAndroid()) {
        startPlayer = 'innie#exo';
      } else if (discHint) {
        startPlayer = 'innie#mpv';
      } else {
        startPlayer = _prefPlayerVal;
      }
      var openPlayer = startPlayer;
      var handoffMs = 0;
      if (kotvIsExternalPlayer(startPlayer)) {
        if (serial != _playAtSerial || !mounted) return;
        final resumeOk = _resumeSeekMs > 0 &&
            ep.name.trim() == _resumeSeekRemarks &&
            (_resumeSeekFlag.isEmpty || flag.flag == _resumeSeekFlag || flag.show == _resumeSeekFlag);
        final resumeMs = resumeOk ? _resumeSeekMs : 0;
        final startMs = _skipOpeningEnding ? math.max(_openingSec * 1000, resumeMs) : resumeMs;
        await _playback.pause();
        if (serial != _playAtSerial || !mounted) return;
        setState(() {
          _playUrl = playUrl;
          _playerVal = startPlayer;
          _prefPlayerVal = startPlayer;
          _status = '外部播放器…';
        });
        final KotvExternalPlayResult handed;
        try {
          handed = await kotvLaunchExternalPlayer(
            player: startPlayer,
            url: playUrl,
            headers: rawHeaders,
            title: '${d.name} · ${ep.name}',
            positionMs: startMs,
            vod: true,
            context: context,
          );
        } catch (e) {
          if (serial == _playAtSerial && mounted) setState(() => _status = '$e');
          return;
        }
        if (serial != _playAtSerial || !mounted) return;
        if (!handed.opened) {
          setState(() => _status = '未打开外部播放器');
          return;
        }
        if (handed.endBy == 'playback_completion') {
          unawaited(_advanceToNextEpisode(fromEnd: false));
          return;
        }
        if (handed.endBy != 'user') {
          setState(() => _status = '已用外部播放器打开');
          return;
        }
        openPlayer = kotvDefaultVodPlayer();
        handoffMs = handed.positionMs;
      }
      final failover = KotvPlaybackFailover(
        playerVal: openPlayer,
        decodeMode: _prefDecodeMode,
        lockExoForDrm: hasDrm && kotvIsAndroid(),
        enabled: KotvPlaybackFailover.enabledFromSetting(_prefPlayerFailover) && !discHint,
      );
      Object? lastOpenError;
      var opened = false;
      var proxySwitched = false;
      final adFilterOn = _adFilterOn;
      final subMaps = _playSubsOf(data);
      final format = _playFormatOf(data);
      for (var attempt = 0; attempt < 8; attempt++) {
        if (serial != _playAtSerial || !mounted) return;
        failover.markAttempt();
        // 先停闲置后端（含旧 FVP），再改 _playerVal，避免换引擎时宿主仍挂旧面。
        final nextVal = failover.playerVal;
        final nextDecode = failover.decodeMode;
        await _stopInactiveBackends(kotvEmbedBackend(nextVal));
        if (serial != _playAtSerial || !mounted) return;
        _playerVal = nextVal;
        _decodeMode = nextDecode;
        final pb = _playback;
        // failover 新建的 Exo 默认 surface；先写入设置里的 playerRender 再 setRenderMode/create。
        if (pb is ExoPlayback) {
          if (playSettings.isNotEmpty) {
            pb.applyPlayerOptions(playSettings);
          } else {
            pb.applyPlayerOptions({'playerRender': renderMode});
          }
          // 外挂字幕须在 open 前写入，才能进 MediaItem。
          pb.setExternalSubs(subMaps);
        } else if (playSettings.isNotEmpty) {
          _fvp?.applyPlayerOptions(playSettings);
        }
        await pb.setDecodeMode(failover.decodeMode);
        await pb.setRenderMode(renderMode);
        final target = _openTargetOf(
          playerVal: failover.playerVal,
          playUrl: playUrl,
          mediaUrl: mediaUrl,
          directUrl: directUrl,
          rawHeaders: rawHeaders,
          magnet: magnet,
          format: format,
          adFilterOn: adFilterOn,
          forceProxy: proxySwitched,
        );
        var openUrl = target.url;
        final openHeaders = target.headers;
        final disc = KotvDiscPlay.openPlanAny([openUrl, ep.url, mediaUrl]);
        if (disc != null) {
          openUrl = disc.url;
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
          // 每次 open 复位 force-iso，避免会话复用粘滞。
          pb.setExtraOpenProps(KotvDiscPlay.openPropsFor(disc?.props));
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
              await pb.setVolume(vol);
            } catch (_) {}
          }
          try {
            await pb.setRepeatOne(_repeatOne);
          } catch (_) {}
          // 起播缓冲由守卫无限等待；仅黑屏/视源失败抛 SilentVideo 才 failover。
          // 勿再套墙钟 timeout：慢源会被误切播放器。
          // 续播与片头合成起点，经 open(startAt) 在首次 play 前定位。
          // ADB：open 返回前若 _openingSeekDone 仍为 false，进度回调会再 seek →
          // 第二次 MediaCodec flush → Render Avg≈1000ms（约 1fps）。
          // 仅 remarks/flag 与历史一致才吃续播，避免点其它集误带进度。
          final resumeOk = handoffMs <= 0 &&
              _resumeSeekMs > 0 &&
              ep.name.trim() == _resumeSeekRemarks &&
              (_resumeSeekFlag.isEmpty || flag.flag == _resumeSeekFlag || flag.show == _resumeSeekFlag);
          final resumeMs = resumeOk ? _resumeSeekMs : 0;
          _clearResumeSeek();
          final startMs = handoffMs > 0
              ? handoffMs
              : (_skipOpeningEnding ? math.max(_openingSec * 1000, resumeMs) : resumeMs);
          // 片头已并入 startAt：必须在 open 之前置位，堵住 open 内 guard 期间的二次 seek。
          if (_skipOpeningEnding || startMs > 0) {
            _openingSeekDone = true;
          }
          // Win7：先量槽建 HWND（快）→ await 推底栏 → 最后 open 里 mpv_initialize。
          // 若把 initialize 放进 updateFrame，UI 未响应时底栏 Layout 永远排不上。
          if (KotvWinChrome.isNeeded) {
            final ok = await _ensureWin7VideoSlotFrame();
            if (!ok) {
              throw StateError('视频槽未就绪');
            }
            if (!_immersiveFullscreen) {
              await _pushWinInlineChromeNow();
            }
          } else if (!_immersiveFullscreen) {
            _bindWinInlineChrome();
          }
          // 开播标定 live；引擎 media-live / isLive 仅供守卫，不预拉节目单。
          await pb.open(
            openUrl,
            headers: openHeaders,
            drm: hasDrm ? drm : null,
            format: format,
            startAt: Duration(milliseconds: startMs),
          );
          if (KotvWinChrome.isNeeded && _immersiveFullscreen) KotvMpvUnderlayHole.resyncAll(force: true);
          if (serial != _playAtSerial || !mounted) {
            await kotvStopIfUnowned(pb, [_mk, _fvp, _exo, _html, _art, _xg, _zw]);
            return;
          }
          try {
            await pb.play();
          } catch (_) {}
          opened = true;
          break;
        } on KotvSilentVideoException catch (e) {
          if (serial != _playAtSerial || !mounted) {
            await kotvStopIfUnowned(pb, [_mk, _fvp, _exo, _html, _art, _xg, _zw]);
            return;
          }
          lastOpenError = e;
          // 非 Exo：直连不可播时改开本集已下发的透传 url（不二次请求）。
          if (kotvShouldSwitchToProxyAfterOpenFailure(
            playerVal: failover.playerVal,
            openUrl: openUrl,
            playUrl: playUrl,
            alreadySwitched: proxySwitched,
          )) {
            proxySwitched = true;
            if (mounted) {
              setState(() => _status = '$_enginePrefix 改走透传重试…');
            }
            continue;
          }
          final retry = await _recoverAfterSilentVideo(
            pb: pb,
            failover: failover,
            serial: serial,
          );
          if (retry == null) return;
          if (retry) continue;
          if (!failover.enabled) {
            // keepSession：关闭自动切换时不判失败，留在当前引擎。
            opened = true;
          }
          break;
        }
      }
      if (!opened) {
        throw lastOpenError ?? const KotvSilentVideoException();
      }
      if (serial != _playAtSerial || !mounted) return;
      // 音量/倍速已在 open 前套好；稳定音量起播后立刻挂，勿再拖 800ms。
      // FVP 跳过（见 FvpPlayback.setStableVolume）。
      if (_stableVolumeOn && _backend != KotvEmbedBackend.fvp) {
        try {
          await _applyStableVolume(_playback, true);
        } catch (_) {}
      }
      if (!mounted) return;
      _spiderDanmakuSources = kotvDanmakuSourcesFrom(data['danmaku']);
      unawaited(_loadDanmakuForEpisode(name: d.name, episode: ep.name, playSerial: serial));
      _applySourceMeta(data);
      // 仍未 READY：等进度回调 _markPlaybackLiveIfNeeded（STATE_READY 才挂 Clock）
      _playbackLive = false;
      _sessionStartedAt = DateTime.now();
      if (gen == _playGen) {
        _wireEpisodeEnd(_playback);
        _wirePosition(_playback);
        _wirePlaybackNotify(_playback);
      }
      _stopBtProgressPoll();
      _syncPlayStatus();
      ref.read(remoteBridgeProvider)?.reportMedia(state: 'playing', title: '${d.name} · ${ep.name}', url: playUrl);
      // 网盘/磁力：引擎 cloud 标志；起播后后台入下载列表（去重）。
      _enqueueCloudPlayIfNeeded(
        cloud: data['cloud'] == true || magnet,
        site: _detailSite(),
        vodId: _detailId(),
        title: (d.name).trim().isEmpty ? _routeTitle : d.name.trim(),
        flag: flag.flag,
        pic: d.pic,
        epIndex: epIdx,
        epName: ep.name,
        epUrl: ep.url,
      );
      if (fullscreen && mounted) {
        await _enterFullscreen();
      }
    } catch (e) {
      if (serial != _playAtSerial) return;
      if (kotvMessageNeedsLogin(e)) {
        final ok = await kotvPresentLoginIfNeeded(context, ref);
        if (ok && mounted && serial == _playAtSerial) {
          unawaited(_playAt(epIdx, fullscreen: fullscreen));
        }
        return;
      }
      _stopBtProgressPoll();
      _playbackLive = false;
      _sessionStartedAt = null;
      final tip = _friendlyPlayError(
        e,
        triedSwitch: KotvPlaybackFailover.enabledFromSetting(_prefPlayerFailover),
      );
      // 留页并保留舞台；勿清 _playUrl 拆掉播放区。
      if (mounted) {
        setState(() {
          _immersiveEpCover = false;
          _status = tip;
        });
        _syncAndroidAutoPip();
        _syncFullscreen();
      }
    }
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
    if (s.contains('空') && s.toLowerCase().contains('url')) return '播放地址加载失败';
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
  /// 纯音频时叠 [KotvAudioStage]，各入口共用，避免黑屏。
  Widget _buildSharedVideo({BoxFit fit = BoxFit.contain}) {
    Widget inner = kotvPlaybackView(
      playerVal: _playerVal,
      playback: _playback,
      mpv: _mk,
      fit: fit,
    );
    // 原生视频层：跨布局保活。
    if (_mk is NativeMpvPlayback) {
      inner = KeyedSubtree(key: _videoHostKey, child: inner);
    }
    final ratio = _aspect.ratio;
    final mpvNativeScale = _mk is NativeMpvPlayback;
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
      inner = ValueListenableBuilder<int>(
        valueListenable: m.surfaceRev,
        builder: (context, _, child) => child!,
        child: inner,
      );
    }
    final pb = _existingPlayback;
    return Stack(
      fit: StackFit.expand,
      children: [
        inner,
        if (pb != null)
          kotvAudioStageOverlay(
            playback: pb,
            coverUrl: _detail?.pic ?? '',
          ),
      ],
    );
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
  /// 把黑槽与顶栏下内容区在详情 Stack 内的矩形写入 [_videoLayerRect] / [_bodyClipRect]。
  /// 沉浸期间禁止 sync：setState 会 rebuild 包着 Hybrid Surface 的 Positioned。
  /// 退出全屏后再量槽（见 [_exitImmersiveFullscreen]）。
  void _syncVideoSlotRect() {
    if (!mounted || !_useStableVideoLayer || _immersiveFullscreen) return;
    final slotBox = _videoSlotKey.currentContext?.findRenderObject() as RenderBox?;
    final bodyBox = _bodyClipKey.currentContext?.findRenderObject() as RenderBox?;
    final stackBox = _detailStackKey.currentContext?.findRenderObject() as RenderBox?;
    if (stackBox == null || !stackBox.hasSize || !stackBox.attached) return;

    Rect? nextSlot;
    if (slotBox != null && slotBox.hasSize && slotBox.attached) {
      try {
        final o = slotBox.localToGlobal(Offset.zero, ancestor: stackBox);
        final r = o & slotBox.size;
        if (r.width >= 1 && r.height >= 1) nextSlot = r;
      } catch (_) {}
    }

    Rect? nextClip;
    if (bodyBox != null && bodyBox.hasSize && bodyBox.attached) {
      try {
        final o = bodyBox.localToGlobal(Offset.zero, ancestor: stackBox);
        final r = o & bodyBox.size;
        if (r.width >= 1 && r.height >= 1) nextClip = r;
      } catch (_) {}
    }

    final prevSlot = _videoLayerRect;
    final prevClip = _bodyClipRect;
    final slotSame = nextSlot == null ||
        (prevSlot != null &&
            (prevSlot.left - nextSlot.left).abs() < 0.5 &&
            (prevSlot.top - nextSlot.top).abs() < 0.5 &&
            (prevSlot.width - nextSlot.width).abs() < 0.5 &&
            (prevSlot.height - nextSlot.height).abs() < 0.5);
    final clipSame = nextClip == null ||
        (prevClip != null &&
            (prevClip.left - nextClip.left).abs() < 0.5 &&
            (prevClip.top - nextClip.top).abs() < 0.5 &&
            (prevClip.width - nextClip.width).abs() < 0.5 &&
            (prevClip.height - nextClip.height).abs() < 0.5);
    if (slotSame && clipSame) {
      _syncWinInlineChrome();
      return;
    }
    setState(() {
      if (nextSlot != null) _videoLayerRect = nextSlot;
      if (nextClip != null) _bodyClipRect = nextClip;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncWinInlineChrome();
    });
  }

  /// 黑槽占位；LayoutBuilder 捕获不经 rebuild 的布局变化以刷新 [_videoLayerRect]。
  Widget _buildVideoSlot() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final prev = _videoLayerRect;
        if (!_immersiveFullscreen &&
            size.width >= 1 &&
            size.height >= 1 &&
            (prev == null ||
                _bodyClipRect == null ||
                (prev.width - size.width).abs() >= 0.5 ||
                (prev.height - size.height).abs() >= 0.5)) {
          _scheduleSyncVideoSlot();
        }
        return ColoredBox(key: _videoSlotKey, color: Colors.black);
      },
    );
  }

  /// [stackSize]：详情 Stack 实测约束。沉浸全屏勿用 MediaQuery 整窗尺寸——
  /// 若底栏/SafeArea 仍占位，整窗高会比可见区大，contain 居中会明显偏下。
  Rect _stableVideoRect(BuildContext context, {Size? stackSize}) {
    final holdFullscreen = _immersiveFullscreen || _holdImmersiveVideoGeom;
    if (holdFullscreen) {
      // hold：优先用退出前的整屏矩形，避免立刻缩到详情槽卸掉 Surface。
      if (_holdImmersiveVideoGeom &&
          _lastVideoPaintRect != null &&
          _lastVideoPaintRect!.width >= 1 &&
          _lastVideoPaintRect!.height >= 1) {
        return _lastVideoPaintRect!;
      }
      final s = (stackSize != null && stackSize.width >= 1 && stackSize.height >= 1)
          ? stackSize
          : MediaQuery.sizeOf(context);
      var r = Offset.zero & s;
      // 氛围模式：画面略内缩，四周透出壳层壁纸（默认适应仍是黑边）。Win7 原生播控无氛围，视频 HWND 铺满。
      if (_ambientOn && r.width > 80 && r.height > 96) {
        return Rect.fromLTRB(r.left + 28, r.top + 36, r.right - 28, r.bottom - 36);
      }
      return r;
    }
    return _videoLayerRect ?? Rect.zero;
  }

  /// Win7：顶栏下内容区 → 全局坐标，裁 HWND。Win8+ DComp 不裁。
  Rect? _underlayGlobalClip() {
    if (!kotvUsesWindowsNativeChrome()) return null;
    if (_immersiveFullscreen || _holdImmersiveVideoGeom) return null;
    final clip = _bodyClipRect;
    final stackBox = _detailStackKey.currentContext?.findRenderObject() as RenderBox?;
    if (clip == null || stackBox == null || !stackBox.hasSize || !stackBox.attached) {
      return null;
    }
    try {
      final o = stackBox.localToGlobal(clip.topLeft);
      return o & clip.size;
    } catch (_) {
      return null;
    }
  }

  Widget _buildStableVideoLayer(BuildContext context, {Size? stackSize}) {
    final holdFullscreen = _immersiveFullscreen || _holdImmersiveVideoGeom;
    final rect = _stableVideoRect(context, stackSize: stackSize);
    Rect? paint = (rect.width >= 1 && rect.height >= 1) ? rect : null;
    if (!holdFullscreen) {
      paint ??= (_videoLayerRect != null &&
              _videoLayerRect!.width >= 1 &&
              _videoLayerRect!.height >= 1)
          ? _videoLayerRect
          : null;
    }
    paint ??= (_lastVideoPaintRect != null &&
            _lastVideoPaintRect!.width >= 1 &&
            _lastVideoPaintRect!.height >= 1)
        ? _lastVideoPaintRect
        : null;
    final stack = (stackSize != null && stackSize.width >= 1 && stackSize.height >= 1)
        ? stackSize
        : MediaQuery.sizeOf(context);
    // 沉浸/hold：无几何时用 Stack 尺寸顶住，避免 shrink 卸掉 Hybrid PlatformView。
    if (paint == null && _playUrl.isNotEmpty && holdFullscreen) {
      if (stack.width >= 1 && stack.height >= 1) paint = Offset.zero & stack;
    }
    if (paint == null) return const SizedBox.shrink();
    if (!_holdImmersiveVideoGeom) {
      _lastVideoPaintRect = paint;
    }

    // 裁剪宿主：沉浸/hold=整屏几何；非全屏=顶栏下 Expanded。
    Rect? clip;
    if (holdFullscreen) {
      clip = paint;
    } else {
      clip = _bodyClipRect;
    }
    if (clip == null || clip.width < 1 || clip.height < 1) {
      if (_playUrl.isEmpty) return const SizedBox.shrink();
      clip = paint;
    }

    final underlayClip = _underlayGlobalClip();
    // Win7：洞 HWND 与黑槽/surface 同全局矩形，避免自测缩到左上角；高度避开底栏。
    Rect? forcedGeom;
    if (kotvUsesWindowsNativeChrome() && !holdFullscreen) {
      final slot = _winRectOf(_videoSlotKey);
      final surface = _winRectOf(_inlineSurfaceKey);
      final m = slot ?? surface;
      if (m != null) {
        final v = _winVideoFrameAvoidInlineChrome(m);
        forcedGeom = Rect.fromLTWH(v['left']!, v['top']!, v['width']!, v['height']!);
      } else {
        final stackBox =
            _detailStackKey.currentContext?.findRenderObject() as RenderBox?;
        if (stackBox != null && stackBox.hasSize && stackBox.attached) {
          try {
            final full = stackBox.localToGlobal(paint.topLeft) & paint.size;
            final v = _winVideoFrameAvoidInlineChrome({
              'left': full.left,
              'top': full.top,
              'width': full.width,
              'height': full.height,
            });
            forcedGeom = Rect.fromLTWH(v['left']!, v['top']!, v['width']!, v['height']!);
          } catch (_) {}
        }
      }
    }
    return ValueListenableBuilder<double>(
      valueListenable: _fsSwipeDy,
      builder: (context, swipeDy, child) {
        final dy = _immersiveFullscreen ? swipeDy : 0.0;
        Widget layer = ClipRect(
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              Positioned(
                left: paint!.left - clip!.left,
                top: paint.top - clip.top + dy,
                width: paint.width,
                height: paint.height,
                child: child!,
              ),
            ],
          ),
        );
        if (underlayClip != null) {
          layer = KotvMpvUnderlayClip(globalClip: underlayClip, child: layer);
        }
        if (forcedGeom != null) {
          layer = KotvMpvForcedGeom(globalRect: forcedGeom, child: layer);
        }
        return Positioned(
          left: clip.left,
          top: clip.top,
          width: clip.width,
          height: clip.height,
          child: layer,
        );
      },
      // Win7 全屏/铺满：命中交给原生 gesture HWND，Flutter 视频层不抢点。
      child: IgnorePointer(
        ignoring: KotvWinChrome.isNeeded && holdFullscreen,
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
            : () => unawaited(_cycleImmersiveByDoubleTap()),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // letterbox：Texture/HWND 用黑底；macOS underlay 洞后透明（洞外 contentView.layer 黑）。
            kotvMpvLetterboxFill(),
            ExcludeFocus(child: _buildSharedVideo(fit: _aspect.fit)),
            // 仅 Android：解析/无帧/起播缓冲盖住 Hybrid Surface，防叠影。
            // 勿用 stalling：中途 STATE_BUFFERING 也会盖黑最后一帧（Exo 点播极卡）。
            if (kotvIsAndroid())
              ListenableBuilder(
                listenable: _playback,
                builder: (context, _) {
                  final parsing = _status.contains('解析') ||
                      _status.contains('嗅探') ||
                      _status.contains('换集中');
                  // 纯音频无尺寸是正常态，勿盖黑挡掉音频叠层。
                  final noFrame = kotvNeedsBlankSurfaceCover(_playback);
                  final startBuf = !_playback.playing && _playback.buffering;
                  final cover = parsing || noFrame || startBuf;
                  if (!cover) return const SizedBox.shrink();
                  return const ColoredBox(color: Colors.black);
                },
              ),
            if (_immersiveFullscreen) ...[
              // 全屏控件在外层；此处不叠内嵌解析/中心钮。
            ] else ...[
              Builder(
                builder: (context) {
                  // Win7：槽挖空，解析/缓冲/中心钮/弹幕全由原生 HWND 承接，勿在 Flutter 槽里画。
                  if (KotvWinChrome.isNeeded) return const SizedBox.shrink();
                  final pb = _existingPlayback;
                  final parsing = _status.contains('解析') ||
                      _status.contains('嗅探') ||
                      _status.contains('换集中');
                  if (pb == null) {
                    // 尚无播放器实例（解析中或未起播）：勿 [_playback] 惰性建实例。
                    if (!parsing) return const SizedBox.shrink();
                    return const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(color: Colors.white70),
                          SizedBox(height: 12),
                          Text('正在解析播放地址', style: TextStyle(color: Colors.white70, fontSize: 13)),
                        ],
                      ),
                    );
                  }
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      ValueListenableBuilder<List<DanmakuItem>>(
                        valueListenable: _danmakuItems,
                        builder: (context, items, _) {
                          return DanmakuOverlay(
                          enabled: _danmakuOn,
                          player: pb,
                          items: items,
                          fontSize: _danmakuSize,
                          opacity: _danmakuOpacity,
                          rows: _danmakuRows,
                          maxOnScreen: _danmakuMaxOnScreen,
                          scrollAreaRatio: _danmakuScrollArea,
                          showScroll: _danmakuShowScroll,
                          showTop: _danmakuShowTop,
                          showBottom: _danmakuShowBottom,
                          showReverse: _danmakuShowReverse,
                          showSpecial: _danmakuShowSpecial,
                          showPositioned: _danmakuShowPositioned,
                          bold: _danmakuBold,
                          durationMs: _danmakuDurationMs,
                          fixedDurationMs: _danmakuFixedDurationMs,
                          lineSpacing: _danmakuLineSpacing,
                          strokeMode: _danmakuStrokeMode,
                          colorMode: _danmakuColorMode,
                          rowsTop: _danmakuRowsTop,
                          rowsBottom: _danmakuRowsBottom,
                          fontFamily: _danmakuFontFamily,
                          scrollGapRatio: _danmakuScrollGap,
                          strokeWidth: _danmakuStrokeWidth,
                          shadowOpacity: _danmakuShadowOpacity,
                          projectionOffsetX: _danmakuProjectionOffsetX,
                          projectionOffsetY: _danmakuProjectionOffsetY,
                          projectionOpacity: _danmakuProjectionOpacity,
                        );
                        },
                      ),
                      KotvBufferingOverlay(
                        player: pb,
                        force: parsing,
                        forceText: parsing ? '正在解析播放地址' : null,
                      ),
                      ExcludeFocus(
                        child: CenterPlayPauseButton(
                          player: pb,
                          hideWhenBuffering: true,
                          enabled: !parsing,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ],
          ],
        ),
      ),
      ),
    );
  }

  /// 全屏控件跟详情 setState；勿再用 ValueNotifier 整页重建（GlobalKey 易卸树成环）。
  void _syncFullscreen() {
    if (!mounted || !_immersiveFullscreen) return;
    setState(() {});
  }

  Future<void> _reapplyPlayerFxSettings() async {
    try {
      final settings = await KotvSettingsCache.fetch(ref.read(apiProvider));
      if (!mounted) return;
      _mpvOpts = KotvMpvOpts.fromSettings(settings, decodeMode: _decodeMode);
      kotvPushPlayerSettings(
        settings,
        mpvOpts: _mpvOpts,
        current: _playback,
        mpv: _mk,
        exo: _exo,
        fvp: _fvp,
      );
    } catch (_) {}
  }

  /// 把接口里的弹幕参数写进当前画面。
  /// [applyOffset] 只在起播时记下时轴；之后改偏移走增量平移，读回不再加一次。
  void _applyDanmakuPrefsFromSettings(Map<String, dynamic> settings, {bool applyOffset = false}) {
    _danmakuOn = kotvSettingsMapFlag(settings, 'danmaku', def: true);
    _danmakuSize = double.tryParse('${settings['danmakuSize'] ?? ''}') ?? 18;
    final op = double.tryParse('${settings['danmakuOpacity'] ?? ''}');
    _danmakuOpacity = op == null ? 0.85 : (op > 1 ? op / 100.0 : op).clamp(0.15, 1.0);
    _danmakuRows = int.tryParse('${settings['danmakuRows'] ?? ''}') ?? 6;
    _danmakuMaxOnScreen = int.tryParse('${settings['danmakuMaxOnScreen'] ?? '150'}') ?? 150;
    final sa = double.tryParse('${settings['danmakuScrollArea'] ?? '50'}');
    _danmakuScrollArea = sa == null ? 0.5 : (sa > 1 ? sa / 100.0 : sa).clamp(0.1, 1.0);
    _danmakuShowScroll = kotvSettingsMapFlag(settings, 'danmakuShowScroll', def: true);
    _danmakuShowTop = kotvSettingsMapFlag(settings, 'danmakuShowTop', def: true);
    _danmakuShowBottom = kotvSettingsMapFlag(settings, 'danmakuShowBottom', def: true);
    _danmakuShowReverse = kotvSettingsMapFlag(settings, 'danmakuShowReverse', def: true);
    _danmakuShowSpecial = kotvSettingsMapFlag(settings, 'danmakuShowSpecial', def: true);
    _danmakuShowPositioned = kotvSettingsMapFlag(settings, 'danmakuShowPositioned', def: true);
    _danmakuBold = kotvSettingsMapFlag(settings, 'danmakuBold');
    _danmakuDurationMs = int.tryParse('${settings['danmakuDurationMs'] ?? '8000'}') ?? 8000;
    _danmakuFixedDurationMs = int.tryParse('${settings['danmakuFixedDurationMs'] ?? '5000'}') ?? 5000;
    _danmakuLineSpacing = double.tryParse('${settings['danmakuLineSpacing'] ?? '1.4'}') ?? 1.4;
    _danmakuStrokeMode = kotvNormalizeDanmakuStroke('${settings['danmakuStrokeMode'] ?? 'outline'}');
    _danmakuColorMode = kotvNormalizeDanmakuColorMode('${settings['danmakuColorMode'] ?? 'original'}');
    _danmakuFontFamily = kotvNormalizeSubtitleFont('${settings['danmakuFont'] ?? 'default'}');
    _danmakuRowsTop = (int.tryParse('${settings['danmakuRowsTop'] ?? '3'}') ?? 3).clamp(1, 8);
    _danmakuRowsBottom = (int.tryParse('${settings['danmakuRowsBottom'] ?? '3'}') ?? 3).clamp(1, 8);
    final gapRaw = double.tryParse('${settings['danmakuScrollGap'] ?? '8'}') ?? 8;
    _danmakuScrollGap = (gapRaw > 1 ? gapRaw / 100.0 : gapRaw).clamp(0.0, 0.2);
    _danmakuStrokeWidth = (double.tryParse('${settings['danmakuStrokeWidth'] ?? '0.12'}') ?? 0.12).clamp(0.05, 0.3);
    _danmakuShadowOpacity = (double.tryParse('${settings['danmakuShadowOpacity'] ?? '0.5'}') ?? 0.5).clamp(0.0, 0.9);
    _danmakuProjectionOffsetX = (double.tryParse('${settings['danmakuProjectionOffsetX'] ?? '0.08'}') ?? 0.08).clamp(0.02, 0.15);
    _danmakuProjectionOffsetY = (double.tryParse('${settings['danmakuProjectionOffsetY'] ?? '0.08'}') ?? 0.08).clamp(0.02, 0.15);
    _danmakuProjectionOpacity = (double.tryParse('${settings['danmakuProjectionOpacity'] ?? '0.2'}') ?? 0.2).clamp(0.0, 0.9);
    if (applyOffset) {
      _danmakuOffsetSec = ((int.tryParse('${settings['danmakuOffsetMs'] ?? '0'}') ?? 0) / 1000.0);
    }
  }

  Future<void> _refreshDanmakuPrefs() async {
    try {
      final settings = await KotvSettingsCache.fetch(ref.read(apiProvider));
      if (!mounted) return;
      setState(() => _applyDanmakuPrefsFromSettings(settings));
    } catch (_) {}
  }

  Widget _buildImmersiveFullscreenPage({bool externalVideo = false}) {
    final d = _detail!;
    final api = ref.read(apiProvider);
    final id = _detailId();
    final site = _detailSite();
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
        prefDecodeMode: _prefDecodeMode,
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
        danmakuMaxOnScreen: _danmakuMaxOnScreen,
        danmakuScrollArea: _danmakuScrollArea,
        danmakuShowScroll: _danmakuShowScroll,
        danmakuShowTop: _danmakuShowTop,
        danmakuShowBottom: _danmakuShowBottom,
        danmakuShowReverse: _danmakuShowReverse,
        danmakuShowSpecial: _danmakuShowSpecial,
        danmakuShowPositioned: _danmakuShowPositioned,
        danmakuBold: _danmakuBold,
        danmakuDurationMs: _danmakuDurationMs,
        danmakuFixedDurationMs: _danmakuFixedDurationMs,
        danmakuLineSpacing: _danmakuLineSpacing,
        danmakuStrokeMode: _danmakuStrokeMode,
        danmakuColorMode: _danmakuColorMode,
        danmakuFontFamily: _danmakuFontFamily,
        danmakuRowsTop: _danmakuRowsTop,
        danmakuRowsBottom: _danmakuRowsBottom,
        danmakuScrollGap: _danmakuScrollGap,
        danmakuStrokeWidth: _danmakuStrokeWidth,
        danmakuShadowOpacity: _danmakuShadowOpacity,
        danmakuProjectionOffsetX: _danmakuProjectionOffsetX,
        danmakuProjectionOffsetY: _danmakuProjectionOffsetY,
        danmakuProjectionOpacity: _danmakuProjectionOpacity,
        danmakuSources: _danmakuSources,
        danmakuSourceIdx: _danmakuSourceIdx,
        onDanmakuSourceChanged: (i) {
          if (!mounted || i < 0 || i >= _danmakuSources.length) return;
          setState(() => _danmakuSourceIdx = i);
          unawaited(_loadDanmakuSource(i, notify: true));
        },
        onDanmakuSearch: () => unawaited(_searchDanmaku()),
        onDanmakuSettingsChanged: () => unawaited(_refreshDanmakuPrefs()),
        ambientOn: _ambientOn,
        stableVolumeOn: _stableVolumeOn,
        holdSpeed: _holdSpeed,
        onAssrtSearch: _searchAssrtSubtitle,
        keepLabel: _kept ? '取消收藏' : '收藏',
        offsetId: id,
        offsetSite: site,
        openingSec: _openingSec,
        endingSec: _endingSec,
        desktopFullscreen: _desktopFs,
        onWinLayoutChanged: () {
          if (mounted) setState(() {});
        },
        onExitEmbedded: () => unawaited(_exitImmersiveFullscreen()),
        onDoubleTapEmbedded: () => unawaited(_cycleImmersiveByDoubleTap()),
        onOffsetsChanged: (open, end) {
          if (!mounted) return;
          setState(() {
            _openingSec = open;
            _endingSec = end;
          });
        },
        onSelectEp: (i) => unawaited(_onEpisodeTap(i)),
        onNext: () => unawaited(_advanceToNextEpisode(fromEnd: false)),
        onPrev: () => unawaited(_onEpisodeTap(_epIdx - 1)),
        onDecodeChanged: (mode) {
          if (!mounted) return;
          setState(() {
            _decodeMode = mode;
            _prefDecodeMode = mode;
          });
        },
        onRenderChanged: (mode) {
          // 须在 persist/setSetting 完成前重建画面，否则 Texture↔Surface 会音画分离定格。
          if (mounted) {
            setState(() => _renderMode = kotvNormalizePlayerRender(mode));
          }
        },
        onPersistSetting: _persistPlayerSetting,
        onLoadSettings: () async {
          final map = await KotvSettingsCache.fetch(api);
          return {for (final e in map.entries) e.key: '${e.value}'};
        },
        onPlayerStatus: api.playerStatus,
        onExternalPlayer: (player) async {
          final live = _playback.isLive;
          final result = await kotvLaunchExternalPlayer(
            player: player,
            url: _playUrl,
            headers: _playHeaders,
            title: _detail?.name ?? '',
            positionMs: live ? 0 : _playback.position.inMilliseconds,
            vod: !live,
            context: context,
          );
          if (!mounted || !result.opened) return false;
          if (result.endBy == 'playback_completion') {
            await _advanceToNextEpisode(fromEnd: false);
            return true;
          }
          if (result.endBy == 'user' && !live && result.positionMs > 0) {
            await _playback.seek(Duration(milliseconds: result.positionMs));
            await _playback.play();
          }
          return true;
        },
        onToggleKeep: () async {
          final kept = await LocalCollect.toggle(_collectItemFromDetail());
          if (mounted) {
            setState(() => _kept = kept);
          }
          return kept ? '取消收藏' : '收藏';
        },
        onAmbientChanged: (v) {
          if (mounted) setState(() => _ambientOn = v);
        },
        onRepeatOneChanged: (v) => unawaited(_setRepeatOne(v)),
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

  Future<void> _runImmersiveTransit(Future<void> Function() op) {
    final prev = _immersiveTransit;
    late final Future<void> next;
    next = prev.catchError((_) {}).then((_) => op());
    _immersiveTransit = next;
    return next;
  }

  /// 双击画面：内嵌→全窗口→系统全屏→内嵌（桌面）；非桌面沉浸态双击直接退出。
  Future<void> _cycleImmersiveByDoubleTap() async {
    if (!_immersiveFullscreen) {
      if (_playUrl.isNotEmpty) {
        await _enterFullscreen(KotvDesktopFullscreenKind.window);
      } else if (_eps.isNotEmpty) {
        await _playAt(_epIdx >= 0 ? _epIdx : 0, fullscreen: true);
      }
      return;
    }
    if (!kotvIsDesktop() && !kIsWeb) {
      await _exitImmersiveFullscreen();
      return;
    }
    if (_desktopFs == KotvDesktopFullscreenKind.window) {
      await _upgradeImmersiveToDisplay();
      return;
    }
    await _exitImmersiveFullscreen();
  }

  Future<void> _enterFullscreen([KotvDesktopFullscreenKind desktopFs = KotvDesktopFullscreenKind.window]) {
    return _runImmersiveTransit(() async {
      final d = _detail;
      if (d == null || !mounted || _playUrl.isEmpty || _immersiveFullscreen) return;
      _holdImmersiveVideoGeom = false;
      if (_miniDesktop) await _exitMini();
      if (!mounted || _immersiveFullscreen) return;
      if (!kotvIsDesktop() && !kIsWeb && !KotvLayout.television) {
        // 手机全屏按系统旋转设置：锁定时竖屏（上下滑切集），点「全屏观看」才横屏。
        await kotvSetPhoneOrientation(KotvPhoneOrientation.follow);
      }
      // 先铺开画面，再进系统全屏（时序收在 kotvEnterSystemFullscreenAfterLayout）。
      // 全窗口 kind 不会改系统窗口。
      _unbindWinInlineChrome();
      ref.read(detailImmersiveFullscreenProvider.notifier).state = true;
      setState(() {
        _desktopFs = desktopFs;
        _immersiveFullscreen = true;
        _fsSwipeDy.value = 0;
      });
      if (!mounted || !_immersiveFullscreen) return;
      await kotvEnterSystemFullscreenAfterLayout(desktopFs);
    });
  }

  /// 已在全窗口沉浸时升为系统全屏（双击第二档）。
  Future<void> _upgradeImmersiveToDisplay() {
    return _runImmersiveTransit(() async {
      if (!mounted || !_immersiveFullscreen) return;
      if (_desktopFs == KotvDesktopFullscreenKind.display) return;
      setState(() => _desktopFs = KotvDesktopFullscreenKind.display);
      if (!mounted || !_immersiveFullscreen) return;
      await kotvEnterSystemFullscreenAfterLayout(KotvDesktopFullscreenKind.display);
    });
  }

  /// 全屏返回：弹窗、右侧选集、底栏、退出全屏。同一按键的第二次投递不再往下关一层。
  Future<void> _handleImmersiveBack() async {
    final now = DateTime.now();
    final until = _immersiveBackUntil;
    if (until != null && now.isBefore(until)) return;
    _immersiveBackUntil = now.add(const Duration(milliseconds: 400));
    if (kotvPopTopPopup(rootNavigatorKey.currentState)) return;
    if (mounted && kotvPopTopPopup(Navigator.of(context, rootNavigator: false))) return;
    if (detailFullscreenDismissLayer?.call() == true) return;
    if (!_immersiveFullscreen && !_holdImmersiveVideoGeom) return;
    await _exitImmersiveFullscreen();
  }

  Future<void> _exitImmersiveFullscreen() {
    return _runImmersiveTransit(() async {
      if (!_immersiveFullscreen && !_holdImmersiveVideoGeom) return;
      // 先挡二次返回：Focus 与 PopScope/壳层常在同一按键上各走一遍。
      _suppressDetailPopUntil = DateTime.now().add(const Duration(milliseconds: 800));
      _fsSwipeDy.value = 0;
      final wasDisplay = _desktopFs == KotvDesktopFullscreenKind.display;
      // 两阶段：先清沉浸标志并 hold 整屏几何，再退系统栏/量槽，最后缩到槽。
      ref.read(detailImmersiveFullscreenProvider.notifier).state = false;
      if (mounted) {
        setState(() {
          _immersiveFullscreen = false;
          _immersiveEpCover = false;
          _holdImmersiveVideoGeom = true;
        });
      } else {
        _holdImmersiveVideoGeom = true;
      }
      await kotvExitSystemFullscreen(wasDisplayFullscreen: wasDisplay);
      if (!mounted) {
        _holdImmersiveVideoGeom = false;
        return;
      }
      if (_immersiveFullscreen) return;
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || _immersiveFullscreen) return;
      _syncVideoSlotRect();
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || _immersiveFullscreen) return;
      if (_holdImmersiveVideoGeom) {
        setState(() => _holdImmersiveVideoGeom = false);
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_immersiveFullscreen) _bindWinInlineChrome();
      });
    });
  }

  Future<void> _cast() async {
    await kotvCastPlaying(
      context,
      ref.read(apiProvider),
      playUrl: _playUrl,
      positionMs: _playback.isLive ? 0 : _playback.position.inMilliseconds,
      isMounted: () => mounted,
      setStatus: (m) => setState(() => _status = m),
      pauseLocal: _playback.pause,
    );
  }

  Future<void> _enterMini() {
    return kotvEnterMiniPlayback(
      context: context,
      isMounted: () => mounted,
      hasMedia: _playUrl.isNotEmpty,
      playback: _playback,
      setState: setState,
      onPip: (inPip) => _miniDesktop = inPip,
      onEntered: () => _miniDesktop = true,
    ).then((_) => _resyncWinAfterMini());
  }

  /// Win7：迷你窗切换后布局整体换掉，等一帧再按新模式推原生壳。
  void _resyncWinAfterMini() {
    if (!KotvWinChrome.isNeeded || !mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _lastWinInlineChromeSnap = null;
      _lastWinVideoFrameSig = null;
      _syncWinInlineChrome();
    });
  }

  Future<void> _exitMini() {
    return kotvExitMiniPlayback(
      isMounted: () => mounted,
      playback: _playback,
      setState: setState,
      onExited: () => _miniDesktop = false,
    ).then((_) => _resyncWinAfterMini());
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
          ? () => unawaited(_cycleImmersiveByDoubleTap())
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
            // 仅占位；真正 Texture / Surface 在 [_buildStableVideoLayer]，按这块槽的矩形摆放。
            _buildVideoSlot()
          else
            // 勿包 ListenableBuilder：position/playing 高频 notify 会重建 Video。
            ExcludeFocus(
              child: _buildSharedVideo(fit: _aspect.fit),
            ),
          if (_playUrl.isNotEmpty && !stableSlot && !KotvWinChrome.isNeeded)
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
          if (_status.startsWith('播放失败') || _status == '播放地址加载失败')
            Positioned.fill(
              child: IgnorePointer(
                ignoring: false,
                child: ColoredBox(
                  color: const Color(0x99000000),
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _status,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            '可换源 / 解析后重试',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white.withOpacity(0.72), fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _inlineChrome() {
    // Win7：HWND 盖住 Flutter 内嵌栏 → 占位量锚，原生 kotv_win_chrome 承接。
    if (KotvWinChrome.isNeeded) {
      return LayoutBuilder(
        builder: (context, c) => SizedBox(
          key: _inlineChromeAnchorKey,
          height: KotvWinChrome.inlineBarHeight(context, c.maxWidth),
          width: double.infinity,
        ),
      );
    }
    return VodInlineControls(
      key: _inlineChromeKey,
      player: _playback,
      miniActive: _miniDesktop,
      autofocusPlay: _chromeRemoteFocus,
      decodeMode: _decodeMode,
      onPersistSetting: _persistPlayerSetting,
      onCast: () => unawaited(_cast()),
      onMini: () => unawaited(_miniDesktop ? _exitMini() : _enterMini()),
      onExpand: (kind) => unawaited(_enterFullscreen(kind)),
      onStop: () async {
        await _stopHardAwait();
        if (_miniDesktop) await _exitMini();
        if (mounted) {
          setState(() {
            _status = '已停止';
          });
        }
      },
    );
  }

  void _bindWinInlineChrome() {
    if (!KotvWinChrome.isNeeded) return;
    if (_immersiveFullscreen || _playUrl.isEmpty) {
      _unbindWinInlineChrome();
      return;
    }
    if (_winChromeToken == 0) {
      _winChromeToken = KotvWinChrome.bind(_onWinInlineChromeEvent);
    }
    _syncWinInlineChrome();
  }

  void _unbindWinInlineChrome() {
    if (!KotvWinChrome.isNeeded) return;
    _winInlineTapTimer?.cancel();
    _winInlineTapTimer = null;
    _winBuffer.label(null);
    if (_winChromeToken == 0) return;
    KotvWinChrome.unbind(_winChromeToken);
    _winChromeToken = 0;
    _lastWinInlineChromeSnap = null;
    _lastWinVideoFrameSig = null;
  }

  Map<String, double>? _winRectOf(GlobalKey key) {
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || !box.attached) return null;
    try {
      final o = box.localToGlobal(Offset.zero);
      final s = box.size;
      if (s.width < 8 || s.height < 8) return null;
      return {
        'left': o.dx,
        'top': o.dy,
        'width': s.width,
        'height': s.height,
      };
    } catch (_) {
      return null;
    }
  }

  /// Win7 详情：视频 HWND 高度扣掉内嵌底栏，避免盖住原生播控。迷你窗底栏半透明叠在画面上。
  Map<String, double> _winVideoFrameAvoidInlineChrome(Map<String, double> video) {
    if (!KotvWinChrome.isNeeded || _immersiveFullscreen || _miniDesktop) return video;
    final ch = KotvWinChrome.inlineBarHeight(context, video['width']!);
    final h = video['height']!;
    if (h <= ch + 8) return video;
    return {
      'left': video['left']!,
      'top': video['top']!,
      'width': video['width']!,
      'height': h - ch,
    };
  }

  /// Win7：有槽才建 HWND。open 前必须 await（仅 CreateWindow，不含 mpv_initialize）。
  Future<bool> _ensureWin7VideoSlotFrame() async {
    if (!kotvUsesWindowsNativeChrome() || !mounted) return true;
    // 满窗口/全屏换集：画面不在详情槽里，按槽下发会把视频缩回槽位；让洞重发整屏几何。
    if (_immersiveFullscreen) {
      KotvMpvUnderlayHole.resyncAll(force: true);
      await WidgetsBinding.instance.endOfFrame;
      return mounted;
    }
    final dpr = MediaQuery.devicePixelRatioOf(context);
    for (var i = 0; i < 20; i++) {
      if (!mounted) return false;
      _syncVideoSlotRect();
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return false;
      final raw = _winRectOf(_videoSlotKey) ?? _winRectOf(_inlineSurfaceKey);
      if (raw != null) {
        final video = _winVideoFrameAvoidInlineChrome(raw);
        await kotvMpvUpdateVideoFrame(
          x: video['left']!,
          y: video['top']!,
          w: video['width']!,
          h: video['height']!,
          dpr: dpr,
        );
        return true;
      }
    }
    return false;
  }

  /// Win7：开播前 await 推内嵌底栏，保证在可能变慢的 open/initialize 之前已经 Layout。
  Future<void> _pushWinInlineChromeNow() async {
    if (!KotvWinChrome.isNeeded || !mounted || _immersiveFullscreen) return;
    if (_playUrl.isEmpty) return;
    for (var i = 0; i < 10; i++) {
      if (!mounted) return;
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      if (!_miniDesktop && _winRectOf(_inlineChromeAnchorKey) == null) continue;
      if (_winChromeToken == 0) {
        _winChromeToken = KotvWinChrome.bind(_onWinInlineChromeEvent);
      }
      _lastWinInlineChromeSnap = null;
      final fields = _winInlineFields();
      if (fields == null) continue;
      _lastWinInlineChromeSnap = fields.toString();
      await KotvWinChrome.update(fields);
      return;
    }
  }

  bool get _winChromeForceBuffering =>
      _status.contains('解析') ||
      _status.contains('嗅探') ||
      _status.contains('换集中') ||
      _status.contains('加载中');

  /// 内嵌底栏 / 迷你窗推给原生的整份状态；锚点未就绪返回 null。
  Map<String, dynamic>? _winInlineFields() {
    final p = _playback;
    final base = <String, dynamic>{
      ...KotvWinChrome.metrics(context),
      ...KotvWinChrome.playbackFields(p, forceBuffering: _winChromeForceBuffering),
      'showDirect': kotvShowDirectOutput(p, _prefDecodeMode),
      'directOn': kotvDirectOutputOn(p, _decodeMode),
      'hasCast': true,
      'hasMini': true,
      'gestures': true,
    };
    // 进度量化到 0.25s，减少 listener 刷屏；几何/播态变化仍立即推。
    base['positionSec'] = ((base['positionSec'] as double) * 4).roundToDouble() / 4;
    base['bufferedSec'] = ((base['bufferedSec'] as double) * 4).roundToDouble() / 4;
    // 同内嵌 KotvBufferingOverlay(force: 解析中, forceText: '正在解析播放地址')。
    final resolving = _status.contains('解析') || _status.contains('嗅探') || _status.contains('换集中');
    base['bufferText'] = _winBuffer.label(
      _existingPlayback,
      force: resolving,
      forceText: resolving ? '正在解析播放地址' : null,
    );
    if (_miniDesktop) {
      return {...base, 'mode': 'mini', 'miniKind': 'vod', 'bottom': true, 'centerVisible': false};
    }
    final anchor = _winRectOf(_inlineChromeAnchorKey);
    if (anchor == null) return null;
    final parsing = _winChromeForceBuffering;
    // 页面滚到顶栏下时，原生画面、播控、弹幕都按顶栏下内容区裁掉（同 Flutter 滚动裁剪）。
    final clip = _underlayGlobalClip();
    return {
      ...base,
      'mode': 'vod_inline',
      'clipScreen': {
        'left': clip?.left ?? 0,
        'top': clip?.top ?? 0,
        'width': clip?.width ?? 0,
        'height': clip?.height ?? 0,
      },
      'anchorScreen': anchor,
      'surfaceScreen': _winRectOf(_inlineSurfaceKey),
      'bottom': true,
      // 同 CenterPlayPauseButton(hideWhenBuffering)：暂停且未缓冲才显示。
      'centerVisible': !parsing && !p.playing && !p.stalling,
    };
  }

  void _syncWinInlineChrome() {
    if (!KotvWinChrome.isNeeded || !mounted) return;
    if (_immersiveFullscreen || _playUrl.isEmpty) {
      _unbindWinInlineChrome();
      return;
    }
    final surface = _winRectOf(_inlineSurfaceKey);
    final slot = _winRectOf(_videoSlotKey);
    // 视频几何不依赖底栏锚点；几何未变勿反复 updateFrame。高度扣底栏避免 HWND 盖播控。
    final rawVideo = slot ?? surface;
    if (rawVideo != null) {
      final video = _winVideoFrameAvoidInlineChrome(rawVideo);
      final clip = _underlayGlobalClip();
      final sig =
          '${video['left']!.toStringAsFixed(1)}|${video['top']!.toStringAsFixed(1)}|'
          '${video['width']!.toStringAsFixed(1)}|${video['height']!.toStringAsFixed(1)}|$clip';
      if (sig != _lastWinVideoFrameSig) {
        _lastWinVideoFrameSig = sig;
        final dpr = MediaQuery.devicePixelRatioOf(context);
        unawaited(kotvMpvUpdateVideoFrame(
          x: video['left']!,
          y: video['top']!,
          w: video['width']!,
          h: video['height']!,
          dpr: dpr,
          clip: clip,
        ));
      }
    }
    final fields = _winInlineFields();
    if (fields == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncWinInlineChrome();
      });
      return;
    }
    if (_winChromeToken == 0) {
      _winChromeToken = KotvWinChrome.bind(_onWinInlineChromeEvent);
    }
    unawaited(KotvWinChrome.setDanmaku(
      enabled: _danmakuOn,
      items: _danmakuItems.value,
      fontSize: _danmakuSize,
      opacity: _danmakuOpacity,
      durationMs: _danmakuDurationMs,
      fixedDurationMs: _danmakuFixedDurationMs,
      rows: _danmakuRows,
      maxOnScreen: _danmakuMaxOnScreen,
      scrollArea: _danmakuScrollArea,
      bold: _danmakuBold,
      showScroll: _danmakuShowScroll,
      showTop: _danmakuShowTop,
      showBottom: _danmakuShowBottom,
      showReverse: _danmakuShowReverse,
      showPositioned: _danmakuShowPositioned,
      showSpecial: _danmakuShowSpecial,
      lineSpacing: _danmakuLineSpacing,
      strokeMode: _danmakuStrokeMode,
      colorMode: _danmakuColorMode,
      rowsTop: _danmakuRowsTop,
      rowsBottom: _danmakuRowsBottom,
      scrollGap: _danmakuScrollGap,
      strokeWidth: _danmakuStrokeWidth,
      shadowOpacity: _danmakuShadowOpacity,
      projectionOffsetX: _danmakuProjectionOffsetX,
      projectionOffsetY: _danmakuProjectionOffsetY,
      projectionOpacity: _danmakuProjectionOpacity,
    ));
    final snap = fields.toString();
    if (snap == _lastWinInlineChromeSnap) return;
    _lastWinInlineChromeSnap = snap;
    unawaited(KotvWinChrome.update(fields));
  }

  /// 原生手势层的单击 / 双击：同内嵌画面 GestureDetector（单击播停，双击进全屏，忙时不响应）。
  void _onWinInlinePointer(Map<String, dynamic> e) {
    final phase = e['phase'] as String? ?? '';
    final pos = Offset((e['x'] as num?)?.toDouble() ?? 0, (e['y'] as num?)?.toDouble() ?? 0);
    if (phase == 'down') {
      _winInlineDownAt = pos;
      return;
    }
    if (phase == 'cancel') {
      _winInlineDownAt = null;
      return;
    }
    if (phase != 'up') return;
    final down = _winInlineDownAt;
    _winInlineDownAt = null;
    if (down == null || (pos - down).distance > kTouchSlop) return;
    if (_winInlineTapTimer?.isActive ?? false) {
      _winInlineTapTimer!.cancel();
      _winInlineTapTimer = null;
      unawaited(_cycleImmersiveByDoubleTap());
      return;
    }
    _winInlineTapTimer = Timer(kDoubleTapTimeout, () {
      _winInlineTapTimer = null;
      if (!mounted || _playUrl.isEmpty || _immersiveFullscreen) return;
      if (_winChromeForceBuffering) return;
      unawaited(_playback.playOrPause());
      setState(() {});
    });
  }

  void _onWinInlineChromeEvent(Map<String, dynamic> e) {
    if (!mounted || _immersiveFullscreen) return;
    switch (e['type'] as String? ?? '') {
      case 'pointer':
        if (!_miniDesktop) _onWinInlinePointer(e);
        break;
      case 'back':
        kotvHandleAppBack?.call();
        break;
      case 'key':
        final ke = KotvWinChrome.keyEventFromMap(e);
        if (ke != null) {
          final node = FocusManager.instance.primaryFocus;
          if (node != null) _onInlinePlayerKey(node, ke);
        }
        break;
      case 'toggle':
        unawaited(_playback.playOrPause());
        break;
      case 'stop':
        unawaited(() async {
          await _stopHardAwait();
          if (_miniDesktop) await _exitMini();
          if (mounted) setState(() => _status = '已停止');
          _unbindWinInlineChrome();
        }());
        break;
      case 'seekFraction':
        if (e['commit'] != true) break;
        final frac = (e['value'] as num?)?.toDouble() ?? 0;
        final dur = _playback.duration;
        if (dur.inMilliseconds > 0) {
          unawaited(_playback.seek(Duration(
            milliseconds: (dur.inMilliseconds * frac.clamp(0.0, 1.0)).round(),
          )));
        }
        break;
      case 'slider':
        if (e['id'] != 'volume') break;
        final v = ((e['value'] as num?)?.toDouble() ?? 0).round().clamp(0, 100);
        unawaited(_playback.setVolume(v.toDouble()));
        if (e['commit'] == true) unawaited(_persistPlayerSetting('playerVolume', '$v'));
        break;
      case 'cast':
        unawaited(_cast());
        break;
      case 'mini':
        unawaited(_miniDesktop ? _exitMini() : _enterMini());
        break;
      case 'direct':
        unawaited(_persistPlayerSetting(
          'mpvDirect',
          kotvWin7DirectNextValue(_playback.directOutput),
        ));
        break;
      case 'sheet':
        if (e['kind'] != 'fullscreenKind') break;
        unawaited(_enterFullscreen(e['id'] == 'display'
            ? KotvDesktopFullscreenKind.display
            : KotvDesktopFullscreenKind.window));
        break;
    }
  }

  /// 播控（内嵌、迷你、全屏）设置落盘后按键名同步本页状态与当前播放器。
  Future<void> _persistPlayerSetting(String k, String v) async {
    await KotvSettingsCache.set(ref.read(apiProvider), k, v);
    if (!mounted) return;
    if (k == 'playerScale') {
      setState(() => _aspect = kotvAspectFromScale(v));
      unawaited(_playback.setVideoScale(v));
    }
    if (k == 'playerAmbient') {
      setState(() => _ambientOn = _ambientFromSetting(v));
    }
    if (k == 'mpvDirect') {
      final on = kotvSettingsFlag(v);
      setState(() => _mpvOpts = _mpvOpts.copyWith(direct: on));
      unawaited(_existingPlayback?.setDirectOutput(on));
    }
    if (k == 'playerBackground') {
      final bg = v.trim().toLowerCase();
      setState(() => _playerBackground = (bg == 'off' || bg == 'audio' || bg == 'pip') ? bg : 'pip');
      _syncAndroidAutoPip();
    }
    if (k == 'playerSpeedLongPress') {
      setState(() {
        _holdSpeed = (double.tryParse(v) ?? _holdSpeed).clamp(2.0, 5.0).toDouble();
      });
    }
    if (k == 'playerSpeed') {
      final s = double.tryParse(v);
      if (s != null && s > 0) {
        setState(() => _prefSpeed = kotvClampPlayRate(s));
        unawaited(_playback.setRate(_prefSpeed!));
      }
    }
    if (k == 'playerVolume') {
      final vol = _normalizePlayerVolumePref(v);
      if (vol != null) {
        setState(() => _prefVolume = vol);
      }
    }
    if (k == 'playerSkipOpeningEnding') {
      setState(() {
        _skipOpeningEnding = kotvSettingsFlag(v, def: true);
      });
    }
    if (k == 'playerStableVolume') {
      final on = v.toLowerCase() == 'true';
      setState(() => _stableVolumeOn = on);
      if (_backend != KotvEmbedBackend.fvp) {
        unawaited(_applyStableVolume(_playback, on));
      }
    }
    if (k == 'danmaku') {
      setState(() => _danmakuOn = v.toLowerCase() == 'true');
    }
    if (k == 'danmakuOffsetMs') {
      final next = ((int.tryParse(v) ?? 0) / 1000.0);
      final delta = next - _danmakuOffsetSec;
      _danmakuOffsetSec = next;
      _danmakuItems.value = kotvShiftDanmaku(_danmakuItems.value, delta);
      if (mounted) setState(() {});
    }
    if (const {'danmakuLoad', 'danmakuAuto', 'danmakuSpiderFirst', 'danmakuApi'}.contains(k)) {
      _reloadDanmakuForCurrentEpisode();
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
    if (k.startsWith('danmaku')) {
      unawaited(_refreshDanmakuPrefs());
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
      unawaited(() async {
        if (_renderMode != next) {
          setState(() => _renderMode = next);
          await _playback.setRenderMode(next);
        }
        // 渲染变更后再推 exo 冷选项（隧道仅 Surface；须等 setRenderMode 完成）。
        await _reapplyPlayerFxSettings();
      }());
    }
    if (k == 'player') {
      final prev = _playerVal;
      final next = kotvClampPlayerVal(v, live: false);
      if (next != prev) {
        if (kotvIsExternalPlayer(next)) {
          setState(() {
            _playerVal = next;
            _prefPlayerVal = next;
          });
        } else {
          unawaited(() async {
            // 先停旧后端画面，再切 _playerVal / 重播。
            await _stopInactiveBackends(kotvEmbedBackend(next));
            if (!mounted) return;
            setState(() {
              _playerVal = next;
              _prefPlayerVal = next;
            });
            if (_epIdx >= 0) await _playAt(_epIdx);
          }());
        }
      }
    }
    // 画面/音频/字幕热更新
    if (k.startsWith('video') ||
        k.startsWith('audio') ||
        k.startsWith('subtitle') ||
        k.startsWith('exo') ||
        k == 'audioPassThrough') {
      unawaited(_reapplyPlayerFxSettings());
    }
  }

  KeyEventResult _onInlinePlayerKey(FocusNode node, KeyEvent event) {
    final isDown = event is KeyDownEvent;
    final isRepeat = event is KeyRepeatEvent;
    if (!isDown && !isRepeat) return KeyEventResult.ignored;
    if (_playUrl.isEmpty) return KeyEventResult.ignored;
    final key = event.logicalKey;

    void seekBy(Duration delta) {
      if (_playback.isLive) return;
      final next = _playback.position + delta;
      unawaited(_playback.seek(next.isNegative ? Duration.zero : next));
    }

    // 焦点仍在选集/线路等页面控件上：方向键交给遍历，勿抢左右做 seek。
    final primary = FocusManager.instance.primaryFocus;
    final onPageUi = primary != null &&
        !identical(primary, node) &&
        !VodInlineChromeScope.focusIsInside();
    if (onPageUi && !_chromeRemoteFocus) {
      return KeyEventResult.ignored;
    }

    // 焦点已经在底栏（停止、进度条等）：上下左右交给控件遍历。
    // 左右 seek 只在焦点不在底栏时做，避免停在停止上按向下被吃掉或改进度。
    if (_chromeRemoteFocus || VodInlineChromeScope.focusIsInside()) {
      if (isDown && kotvIsMenuKey(key)) {
        setState(() => _chromeRemoteFocus = false);
        return KeyEventResult.handled;
      }
      if (kotvIsMediaRewind(key)) {
        seekBy(const Duration(seconds: -10));
        return KeyEventResult.handled;
      }
      if (kotvIsMediaFastForward(key)) {
        seekBy(const Duration(seconds: 10));
        return KeyEventResult.handled;
      }
      if (isDown && (kotvIsEnterKey(key) || kotvIsMediaPlayPause(key))) {
        final primary = FocusManager.instance.primaryFocus;
        if (primary == null || primary == node) {
          unawaited(_playback.playOrPause());
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      }
      // 焦点丢了：方向键先恢复栏内上次焦点，避免只能靠 OK。
      if (isDown && kotvIsDpadNavKey(key) && kotvPrimaryIsEmptyOr(node)) {
        _inlineChromeKey.currentState?.restoreRemoteFocus();
        return KeyEventResult.handled;
      }
      // 上下左右：底栏 / 剧集 TvFocus 横移纵移
      return KeyEventResult.ignored;
    }

    // —— 底栏未获焦 ——
    // 菜单/上下 → 亮底栏并拉焦；左右 → seek（勿再用左右「调菜单」）。
    if (isDown && (kotvIsMenuKey(key) || kotvIsUpKey(key) || kotvIsDownKey(key))) {
      setState(() => _chromeRemoteFocus = true);
      _inlineChromeKey.currentState?.restoreRemoteFocus();
      return KeyEventResult.handled;
    }
    if (kotvIsLeftKey(key) || kotvIsMediaRewind(key)) {
      seekBy(const Duration(seconds: -10));
      return KeyEventResult.handled;
    }
    if (kotvIsRightKey(key) || kotvIsMediaFastForward(key)) {
      seekBy(const Duration(seconds: 10));
      return KeyEventResult.handled;
    }
    if (isDown && (kotvIsEnterKey(key) || kotvIsMediaPlayPause(key))) {
      final primary = FocusManager.instance.primaryFocus;
      if (primary == null || primary == node) {
        unawaited(_playback.playOrPause());
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
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
              decodeMode: _decodeMode,
              onPersistSetting: _persistPlayerSetting,
              onCast: () => unawaited(_cast()),
              onMini: () => unawaited(_exitMini()),
              onExpand: (kind) => unawaited(_enterFullscreen(kind)),
              onStop: () async {
                await _stopHardAwait();
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
      // 顶栏占位在 Column 内留高；真正可点的顶栏叠在 Stack 最上层，
      // 避免 Hybrid Surface 盖住返回/片名（Flutter Clip 对 PlatformView 不可靠）。
      LibraryTopBar buildTopBar() => LibraryTopBar(
            onBack: () => unawaited(_leavePage()),
            onSearch: () => unawaited(_leavePage(afterPop: () => goKotvPage(ref, KotvPage.search))),
            onProfile: () => unawaited(_leavePage(afterPop: () => goKotvPage(ref, KotvPage.profile))),
            onNews: () => showLatestNews(context, ref),
            title: _routeTitle.isNotEmpty ? _routeTitle : '详情',
          );
      // 详情压在壳层 Navigator 上：路由不透明只是不画下层路由，页面透明即透出壳层壁纸（全应用一层）。
      // SafeArea 只包内容：顶栏避开状态栏。
      final detailScaffold = Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              Visibility(
                visible: false,
                maintainSize: true,
                maintainAnimation: true,
                maintainState: true,
                maintainInteractivity: false,
                child: buildTopBar(),
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
          return NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (!_immersiveFullscreen &&
                  (notification is ScrollUpdateNotification || notification is ScrollEndNotification)) {
                _scheduleSyncVideoSlot();
              }
              return false;
            },
            child: Stack(
            key: _detailStackKey,
            fit: StackFit.expand,
            children: [
              // 沉浸默认黑底（各平台一致）：适应 letterbox 不透壳壁纸。
              // 仅氛围模式去掉黑底，四周才透壳层壁纸；Android 仍卸详情树防 Surface 镂空双影
              // （7458fbe / ef4fb2d：稳定 Positioned 宿主，勿整页 Offstage 叠一层 Hybrid）。
              // 桌面 Offstage 保活详情树（退出沉浸不重建）。
              // 沉浸期禁止 _syncVideoSlotRect，避免 setState 重建 Hybrid Positioned。
              if (kotvIsAndroid()) ...[
                if (_immersiveFullscreen && !_ambientOn) const ColoredBox(color: Colors.black),
                if (!_immersiveFullscreen) detailScaffold,
              ] else ...[
                // 全屏 letterbox：underlay 透明，其它平台黑底。
                if (_immersiveFullscreen && !_ambientOn) kotvMpvLetterboxFill(),
                Offstage(
                  offstage: _immersiveFullscreen,
                  child: ExcludeFocus(
                    excluding: _immersiveFullscreen,
                    child: TickerMode(
                      enabled: !_immersiveFullscreen,
                      child: detailScaffold,
                    ),
                  ),
                ),
              ],
              // 叠在 Scaffold 上以便全屏不卸 Texture；沉浸中即使 playUrl 空窗也保 PlatformView。
              if (_playUrl.isNotEmpty || _immersiveFullscreen)
                _buildStableVideoLayer(context, stackSize: stackSize),
              // 换集过渡黑盖：仅 Android Hybrid；桌面 Texture 不盖。
              if (kotvIsAndroid() && _immersiveFullscreen && _immersiveEpCover)
                const Positioned.fill(
                  child: IgnorePointer(child: ColoredBox(color: Colors.black)),
                ),
              // 切集/换播放器时 playUrl 可能短暂变化：全屏页勿随 playUrl 卸树。
              if (_immersiveFullscreen && _detail != null)
                _buildImmersiveFullscreenPage(externalVideo: true),
              // 非全屏：顶栏必须在视频层之上（返回/片名可点可见）。
              // 顶栏自己吃掉壳层没垫的状态栏高度，这里不再加一次。
              if (!_immersiveFullscreen)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: buildTopBar(),
                ),
            ],
            ),
          );
        },
      );
    } else if (_immersiveFullscreen && _detail != null) {
      body = _buildImmersiveFullscreenPage();
    } else {
      body = Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              LibraryTopBar(
                onBack: () => unawaited(_leavePage()),
                onSearch: () => unawaited(_leavePage(afterPop: () => goKotvPage(ref, KotvPage.search))),
                onProfile: () => unawaited(_leavePage(afterPop: () => goKotvPage(ref, KotvPage.profile))),
                onNews: () => showLatestNews(context, ref),
                title: _routeTitle.isNotEmpty ? _routeTitle : '详情',
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
          unawaited(_handleImmersiveBack());
          return;
        }
        // 刚退全屏：同一次返回不要再出详情（全屏返回只上一层）。
        final until = _suppressDetailPopUntil;
        if (until != null && DateTime.now().isBefore(until)) {
          return;
        }
        if (kotvPopTopPopup(rootNavigatorKey.currentState)) return;
        if (kotvPopTopPopup(Navigator.of(context, rootNavigator: false))) return;
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
    final siteKey = d.site.isNotEmpty ? d.site : _routeSite;
    final compact = KotvLayout.isCompact(context);
    final p = KotvPalette.of(context);
    final fg = p.fg;
    final muted = p.muted;
    final introStyle = TextStyle(color: muted, fontSize: 15, height: 1.5);
    final introLinkStyle = TextStyle(
      color: p.primary,
      fontSize: 15,
      height: 1.5,
      decoration: TextDecoration.underline,
      decorationColor: p.primary,
    );

    Widget videoPane({required bool expand}) {
      Widget sized(Widget w) => expand ? w : AspectRatio(aspectRatio: 16 / 9, child: w);
      final stage = _videoStage(interactive: true);
      final Widget pane;
      if (_playUrl.isEmpty) {
        pane = sized(stage);
      } else if (KotvWinChrome.isNeeded) {
        // Win7：视频 HWND 在 Flutter 之上，底栏叠在画面底部，由原生壳按锚点承接。
        pane = sized(Stack(
          key: _inlineSurfaceKey,
          fit: StackFit.expand,
          children: [
            stage,
            Positioned(left: 0, right: 0, bottom: 0, child: _inlineChrome()),
          ],
        ));
      } else {
        // 视频层（PlatformView / 洞）按槽位盖在页面上，Flutter 底栏放在画面下方才不被盖住。
        pane = Column(
          mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
          children: [
            expand ? Expanded(child: stage) : sized(stage),
            _inlineChrome(),
          ],
        );
      }

      return Container(
        decoration: BoxDecoration(
          color: const Color(0xEE0A0A12),
          borderRadius: BorderRadius.circular(14),
        ),
        padding: const EdgeInsets.all(8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          // 画面 ExcludeFocus + 原生 PlatformView 关焦点；控件靠 TvFocus 参与全局遍历。
          child: pane,
        ),
      );
    }

    Widget metaBlock() {
      final info = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          KotvClickableContent(
            raw: d.director,
            prefix: '导演：',
            style: TextStyle(color: muted, fontSize: 15, height: 1.45),
            linkStyle: introLinkStyle.copyWith(fontSize: 15, height: 1.45),
            maxLines: 1,
            onOpen: (c) => _openContentFolder(c, siteKey),
          ),
          const SizedBox(height: 6),
          KotvClickableContent(
            raw: d.actor,
            prefix: '演员：',
            style: TextStyle(color: muted, fontSize: 15, height: 1.45),
            linkStyle: introLinkStyle.copyWith(fontSize: 15, height: 1.45),
            maxLines: 2,
            onOpen: (c) => _openContentFolder(c, siteKey),
          ),
          const SizedBox(height: 6),
          KotvClickableContent(
            raw: d.content,
            prefix: '简介：',
            style: introStyle,
            linkStyle: introLinkStyle,
            maxLines: 3,
            onOpen: (c) => _openContentFolder(c, siteKey),
          ),
        ],
      );
      return TvFocus(
        onPressed: () => _showVodMeta(d),
        borderRadius: 8,
        child: InkWell(
          onTap: () => _showVodMeta(d),
          canRequestFocus: false,
          borderRadius: BorderRadius.circular(8),
          child: Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: info),
        ),
      );
    }

    Widget actionRow() {
      final compactActions = compact || KotvLayout.useBottomNav(context);
      final rowH = compactActions ? 40.0 : 58.0;
      final actions = <(String, IconData, VoidCallback)>[
            ('全屏', Icons.crop_free_rounded, () {
              if (_playUrl.isNotEmpty) {
                unawaited(_enterFullscreen());
              } else if (_epIdx >= 0) {
                unawaited(_playAt(_epIdx, fullscreen: true));
              } else if (eps.isNotEmpty) {
                unawaited(_playAt(0, fullscreen: true));
              }
            }),
            ('搜索', Icons.search_rounded, () {
              final q = d.name.trim();
              unawaited(_leavePage(afterPop: () {
                ref.read(pendingSearchProvider.notifier).state = q;
                goKotvPage(ref, KotvPage.search);
              }));
            }),
            (_reversed ? '正序' : '倒叙', Icons.swap_vert_rounded, () {
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
              unawaited(LocalRevSort.set(_detailId(), _detailSite(), _reversed));
            }),
            (_kept ? '取消收藏' : '收藏', Icons.star_border_rounded, () async {
              final kept = await LocalCollect.toggle(_collectItemFromDetail());
              if (!mounted) return;
              setState(() {
                _kept = kept;
                _status = kept ? '已加入收藏' : '已取消收藏';
              });
            }),
            ('换源', Icons.visibility_outlined, () {
              final name = (_detail?.name ?? _routeTitle).trim();
              if (name.isEmpty) {
                setState(() => _status = '无法换源');
                return;
              }
              unawaited(_leavePage(afterPop: () => searchByName(ref, name)));
            }),
            ('解析', Icons.tune_rounded, () => _pickParse()),
            ('下载', Icons.download_for_offline_outlined, () {
              unawaited(_pickDownloadEpisodes());
            }),
      ];
      // 一排全部放进视口：设计宽度放得下就用设计宽度，否则均分可用宽度。
      return SizedBox(
        height: rowH,
        child: LayoutBuilder(
          builder: (context, c) {
            final m = _actionMetrics();
            final n = actions.length;
            final fit = (c.maxWidth - m.gap * (n - 1)) / n;
            // 向下取整，累加不会因浮点误差超出可用宽度。
            final w = math.min(m.w, fit).floorToDouble();
            return Row(
              children: [
                for (var i = 0; i < n; i++) ...[
                  if (i > 0) SizedBox(width: m.gap),
                  _action(actions[i].$1, actions[i].$2, actions[i].$3, width: w),
                ],
              ],
            );
          },
        ),
      );
    }

    Widget lower() {
      final ui = LayoutScale.grow(context);
      final pillH = compact ? 28.0 : 36.0;
      final pillFs = compact ? 12.0 : 15.0;
      final epM = EpisodeChip.metrics(context);
      final epH = epM.h;
      final epFs = epM.fs;
      final gap = (compact ? 6.0 : 10.0) * ui;
      final srcLabelFs = compact ? 13.0 : 16.0;
      final pillBox = pillH * LayoutScale.layoutOf(context);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(height: (compact ? 8 : 10) * ui),
          Row(
            children: [
              Text('视频来源', style: TextStyle(color: fg, fontSize: srcLabelFs, fontWeight: FontWeight.w700)),
              SizedBox(width: (compact ? 8 : 14) * ui),
              Expanded(
                child: SizedBox(
                  height: pillBox + 2 * ui,
                  child: HScrollList(
                    scrollToIndex: _flagIdx,
                    itemCount: flags.length,
                    separatorBuilder: (_, __) => SizedBox(width: (compact ? 6 : 8) * ui),
                    itemBuilder: (_, i) => AppPill(
                      label: flags[i].show,
                      height: pillH,
                      fontSize: pillFs,
                      selected: i == _flagIdx,
                      // 线路须确认后再切：焦点浏览不改 [_flagIdx]，避免进度/预加载写到未播放线路。
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
            SizedBox(height: (compact ? 8 : 10) * ui),
            SizedBox(
              height: pillBox,
              child: HScrollList(
                scrollToIndex: _epPage,
                itemCount: pageCount,
                separatorBuilder: (_, __) => SizedBox(width: (compact ? 6 : 8) * ui),
                itemBuilder: (_, i) {
                  final from = i * _epSize + 1;
                  final to = ((i + 1) * _epSize).clamp(0, eps.length);
                  return AppPill(
                    label: '$from-$to',
                    height: pillH,
                    fontSize: pillFs,
                    selected: i == _epPage,
                    onFocusChange: (focused) {
                      _detailFocusArm.onFocusChange('ep:$i', focused, () {
                        if (!mounted || i == _epPage) return;
                        setState(() => _epPage = i);
                      });
                    },
                    onTap: () => setState(() => _epPage = i),
                  );
                },
              ),
            ),
          ],
          SizedBox(height: (compact ? 8 : 12) * ui),
          if (pageEps.isEmpty)
            Text('无剧集', style: TextStyle(color: muted))
          else
            // 固定列数网格：格宽随可用宽度均分。勿用算好宽度的 Wrap——
            // Win7 线 Flutter 3.19 的 Wrap 无浮点容差，某些窗口宽度会把末列挤到下一行。
            GridView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: compact ? 3 : 6,
                mainAxisSpacing: gap,
                crossAxisSpacing: gap,
                mainAxisExtent: epH * ui,
              ),
              itemCount: pageEps.length,
              itemBuilder: (_, i) => EpisodeChip(
                label: pageEps[i].name,
                selected: _epIdx == _epPage * _epSize + i,
                height: epH,
                fontSize: epFs,
                onTap: () => unawaited(_onEpisodeTap(_epPage * _epSize + i)),
              ),
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
                children: _remarksMetaChips(siteKey),
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
                          Expanded(
                            child: SingleChildScrollView(
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
                                    children: _remarksMetaChips(siteKey),
                                  ),
                                  const SizedBox(height: 8),
                                  metaBlock(),
                                ],
                              ),
                            ),
                          ),
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

  /// 引擎 `cloud`/`magnet`：起播后入下载列表（勿猜最终 playUrl 形态）。
  void _enqueueCloudPlayIfNeeded({
    required bool cloud,
    required String site,
    required String vodId,
    required String title,
    required String flag,
    required String pic,
    required int epIndex,
    required String epName,
    required String epUrl,
  }) {
    if (!cloud) return;
    if (site.isEmpty || vodId.isEmpty) return;
    final nEps = _eps.length;
    final raw = _reversed ? (nEps - 1 - epIndex) : epIndex;
    unawaited(() async {
      try {
        await LocalDownload.enqueue(
          site: site,
          vodId: vodId,
          title: title,
          flag: flag,
          pic: pic,
          episodes: [
            {
              'index': raw,
              'name': epName,
              'url': epUrl,
            },
          ],
        );
      } catch (e) {
        debugPrint('cloud download enqueue: $e');
      }
    }());
  }

  Future<void> _pickDownloadEpisodes() async {
    final d = _detail;
    final eps = _eps;
    if (d == null || eps.isEmpty) {
      setState(() => _status = '暂无可下载剧集');
      return;
    }
    final flag = d.flags.isEmpty
        ? ''
        : d.flags[_flagIdx.clamp(0, d.flags.length - 1)].flag;
    final site = _detailSite();
    final vodId = _detailId();
    final nEps = eps.length;
    int rawOf(int display) => _reversed ? (nEps - 1 - display) : display;
    Set<int> claimed = {};
    try {
      claimed = LocalDownload.claimedEpIndexes(
        await LocalDownload.list(),
        site: site,
        vodId: vodId,
        flag: flag,
      );
    } catch (_) {}
    bool free(int display) => !claimed.contains(rawOf(display));
    final selected = <int>{};
    if (_epIdx >= 0 && _epIdx < eps.length && free(_epIdx)) {
      selected.add(_epIdx);
    }
    final freeCount = List.generate(eps.length, (i) => i).where(free).length;
    final ok = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (ctx) {
        final pal = KotvPalette.of(ctx);
        final m = MediaQuery.sizeOf(ctx);
        final epM = EpisodeChip.metrics(ctx);
        final epCols = KotvLayout.isCompact(ctx) ? 3 : 4;
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return Dialog(
              backgroundColor: pal.dialogBg,
              child: SizedBox(
                width: m.width > 520 ? 480.0 : m.width * 0.92,
                height: m.height * 0.7,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('选择要下载的剧集',
                          style: TextStyle(
                              color: pal.fg,
                              fontSize: 18,
                              fontWeight: FontWeight.w700)),
                      if (claimed.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text('灰色为已添加，删除下载记录后可再选',
                            style: TextStyle(color: pal.muted, fontSize: 12)),
                      ],
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          AppPill(
                            label: '全选',
                            height: 34,
                            onTap: () => setLocal(() {
                              selected
                                ..clear()
                                ..addAll(List.generate(eps.length, (i) => i)
                                    .where(free));
                            }),
                          ),
                          const SizedBox(width: 8),
                          AppPill(
                            label: '反选',
                            height: 34,
                            onTap: () => setLocal(() {
                              final next = <int>{};
                              for (var i = 0; i < eps.length; i++) {
                                if (!free(i)) continue;
                                if (!selected.contains(i)) next.add(i);
                              }
                              selected
                                ..clear()
                                ..addAll(next);
                            }),
                          ),
                          const Spacer(),
                          Text('${selected.length}/$freeCount',
                              style: TextStyle(color: pal.muted)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: GridView.builder(
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: epCols,
                            mainAxisSpacing: 8,
                            crossAxisSpacing: 8,
                            mainAxisExtent: epM.h * LayoutScale.grow(ctx),
                          ),
                          itemCount: eps.length,
                          itemBuilder: (_, i) {
                            final taken = !free(i);
                            final on = selected.contains(i);
                            // 给定宽度时 AppPill 左右内边距更窄，格子里放得下集名。
                            final pill = AppPill(
                              label: eps[i].name.isEmpty
                                  ? '${i + 1}'
                                  : eps[i].name,
                              selected: on && !taken,
                              width: double.infinity,
                              height: epM.h,
                              fontSize: epM.fs,
                              onTap: taken
                                  ? () {}
                                  : () => setLocal(() {
                                        if (on) {
                                          selected.remove(i);
                                        } else {
                                          selected.add(i);
                                        }
                                      }),
                            );
                            if (!taken) return pill;
                            return Opacity(opacity: 0.38, child: pill);
                          },
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: AppPill(
                              label: '取消',
                              height: 40,
                              onTap: () => Navigator.pop(ctx, false),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: AppPill(
                              label: '开始下载',
                              height: 40,
                              selected: true,
                              onTap: () => Navigator.pop(ctx, true),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
    if (ok != true || !mounted) return;
    selected.removeWhere((i) => !free(i));
    if (selected.isEmpty) {
      setState(() => _status =
          freeCount == 0 ? '所选剧集已在下载列表中' : '请先勾选集数');
      return;
    }
    final episodes = selected.toList()..sort();
    final payload = episodes.map((i) {
      final ep = eps[i];
      return {
        'index': rawOf(i),
        'name': ep.name,
        'url': ep.url,
      };
    }).toList();
    try {
      final res = await LocalDownload.enqueue(
        site: site,
        vodId: vodId,
        title: (d.name).trim().isEmpty ? _routeTitle : d.name.trim(),
        flag: flag,
        pic: d.pic,
        episodes: payload,
      );
      final n = res['count'] ?? payload.length;
      if (!mounted) return;
      setState(() => _status = '已加入 $n 个下载任务');
      final go = await showDialog<bool>(
        context: context,
        useRootNavigator: true,
        builder: (ctx) {
          final pal = KotvPalette.of(ctx);
          return AlertDialog(
            backgroundColor: pal.dialogBg,
            title: Text('已加入下载', style: TextStyle(color: pal.fg)),
            content: Text('已入队 $n 集。是否打开下载任务？',
                style: TextStyle(color: pal.muted)),
            actions: [
              KotvFocusAction(
                  label: '稍后',
                  color: pal.muted,
                  onPressed: () => Navigator.pop(ctx, false)),
              KotvFocusAction(
                  label: '查看任务',
                  color: pal.fg,
                  onPressed: () => Navigator.pop(ctx, true)),
            ],
          );
        },
      );
      if (go == true && mounted) {
        // 叠在详情上打开下载，返回仍回到正在播放的详情（勿 _leavePage 卸掉播放栈）。
        unawaited(Navigator.of(context).push<void>(
          kotvDetailRoute(builder: (_) => const DownloadScreen()),
        ));
      }
    } catch (e) {
      if (mounted) setState(() => _status = '下载入队失败: $e');
    }
  }

  Future<void> _pickParse() async {
    try {
      final st = await ref.read(apiProvider).getSettings();
      KotvSettingsCache.replace(KotvSettingsCache.settingsOf(st));
      final parses = ((st['parses'] as List?) ?? []).whereType<Map>().toList();
      if (parses.isEmpty) {
        setState(() => _status = '当前配置无解析器');
        return;
      }
      final names = parses.map((e) => '${e['name'] ?? ''}').where((e) => e.isNotEmpty).toList();
      final cur = KotvSettingsCache.get('preferredParse');
      final picked = await showDialog<String>(
        context: context,
        useRootNavigator: true,
        builder: (ctx) {
          final pal = KotvPalette.of(ctx);
          final known = names.contains(cur);
          Widget option(String label, String value, {required bool on}) {
            return KotvStableFocus(
              autofocus: on,
              scrollIntoView: true,
              borderRadius: 8,
              onPressed: () => Navigator.pop(ctx, value),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('$label${on ? '  ✓' : ''}', style: TextStyle(color: pal.fg)),
                ),
              ),
            );
          }

          return SimpleDialog(
            backgroundColor: pal.dialogBg,
            title: Text('选择解析器', style: TextStyle(color: pal.fg)),
            children: [
              option('自动（默认）', '', on: cur.isEmpty || !known),
              for (final n in names) option(n, n, on: cur == n),
            ],
          );
        },
      );
      if (picked == null) return;
      await KotvSettingsCache.set(ref.read(apiProvider), 'preferredParse', picked);
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

  /// 详情真实 id（入口路由 id 可能不同）。
  String _detailId() {
    final d = _detail;
    if (d != null && d.id.isNotEmpty) return d.id;
    return _routeId;
  }

  String _detailSite() {
    final d = _detail;
    if (d != null && d.site.isNotEmpty) return d.site;
    return _routeSite;
  }

  /// 音量偏好：≤0 视为脏数据，回退 80；合法范围 1–100。
  double? _normalizePlayerVolumePref(Object? raw) {
    final v = double.tryParse('${raw ?? ''}');
    if (v == null) return null;
    if (v <= 0) return 80;
    return v.clamp(1, 100);
  }

  /// 页内收藏与遥控收藏共用同一 VodItem（含 typeName / remarks / configSource）。
  VodItem _collectItemFromDetail() {
    final d = _detail!;
    return VodItem(
      id: _detailId(),
      name: d.name,
      pic: d.pic,
      site: _detailSite(),
      remarks: d.remarks,
      typeName: d.typeName,
      configSource: _configSource,
    );
  }

  /// 窄屏/宽屏共用的备注 meta chips（更新 CLICKER + 来源/年份/地区）。
  List<Widget> _remarksMetaChips(String siteKey) {
    final d = _detail!;
    final p = KotvPalette.of(context);
    final metaStyle = TextStyle(color: p.muted, fontSize: 14.5, height: 1.3);
    final metaLinkStyle = TextStyle(
      color: p.primary,
      fontSize: 14.5,
      height: 1.3,
      decoration: TextDecoration.underline,
      decorationColor: p.primary,
    );
    return [
      KotvClickableContent(
        raw: d.remarks,
        prefix: '更新：',
        style: metaStyle,
        linkStyle: metaLinkStyle,
        maxLines: 1,
        onOpen: (c) => _openContentFolder(c, siteKey),
      ),
      _meta('来源：${d.site.isEmpty ? '未知' : d.site}'),
      _meta('年份：${d.year.isEmpty ? '暂无' : d.year}'),
      if (d.area.isNotEmpty) _meta('地区：${d.area}'),
    ];
  }

  void _openContentFolder(KotvContentClick click, String site) {
    if (!mounted) return;
    Navigator.of(context).push(
      kotvDetailRoute(
        builder: (_) => FolderScreen(
          tid: click.typeId,
          title: click.typeName.isNotEmpty ? click.typeName : click.label,
          site: site,
        ),
      ),
    );
  }

  void _rememberEmptyTried(String site, String id) {
    final s = site.trim();
    final i = id.trim();
    if (s.isEmpty || i.isEmpty) return;
    for (final e in _emptyTried) {
      if (e.site == s && e.id == i) return;
    }
    _emptyTried.add((site: s, id: i));
  }

  bool _emptyTriedPair(String site, String id) {
    for (final e in _emptyTried) {
      if (e.site == site && e.id == id) return true;
    }
    return false;
  }

  Future<bool> _switchEmptyDetail(String name) async {
    final q = name.trim();
    if (q.isEmpty || _emptyFallbackExhausted) return false;
    _rememberEmptyTried(_routeSite, _routeId);
    try {
      final cfg = await ref.read(apiProvider).getConfig();
      final keys = SiteInfo.listFromConfig(cfg)
          .where((s) => s.searchable && s.changeable && s.key.isNotEmpty)
          .map((s) => s.key)
          .toList();
      if (keys.isEmpty) {
        _emptyFallbackExhausted = true;
        return false;
      }
      final data = await ref.read(apiProvider).search(
        q,
        sites: keys,
        exact: true,
        exclude: [
          for (final e in _emptyTried) {'site': e.site, 'id': e.id},
        ],
      );
      VodItem? hit;
      for (final raw in ((data['list'] as List?) ?? [])) {
        if (raw is! Map) continue;
        final it = VodItem.fromJson(Map<String, dynamic>.from(raw));
        if (it.name.trim() != q || it.id.isEmpty || it.site.isEmpty) continue;
        if (_emptyTriedPair(it.site, it.id)) continue;
        hit = it;
        break;
      }
      if (hit == null || !mounted) {
        if (hit == null) _emptyFallbackExhausted = true;
        return false;
      }
      _rememberEmptyTried(hit.site, hit.id);
      _routeId = hit.id;
      _routeSite = hit.site;
      _routeTitle = hit.name;
      await _load();
      return true;
    } catch (_) {
      return false;
    }
  }

  void _showVodMeta(VodDetail d) {
    final p = KotvPalette.of(context);
    final siteKey = d.site.isNotEmpty ? d.site : _routeSite;
    final bodyStyle = TextStyle(color: p.muted, height: 1.55, fontSize: 15);
    final linkStyle = TextStyle(
      color: p.primary,
      height: 1.55,
      fontSize: 15,
      decoration: TextDecoration.underline,
      decorationColor: p.primary,
    );
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.dialogBg,
        title: Text(d.name, style: TextStyle(color: p.fg)),
        content: SizedBox(
          width: LayoutScale.dp(ctx, 520),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                KotvClickableContent(
                  raw: d.director,
                  prefix: '导演：',
                  style: bodyStyle,
                  linkStyle: linkStyle,
                  onOpen: (c) {
                    Navigator.pop(ctx);
                    _openContentFolder(c, siteKey);
                  },
                ),
                KotvClickableContent(
                  raw: d.actor,
                  prefix: '演员：',
                  style: bodyStyle,
                  linkStyle: linkStyle,
                  onOpen: (c) {
                    Navigator.pop(ctx);
                    _openContentFolder(c, siteKey);
                  },
                ),
                Text(
                  '类型：${d.typeName.isEmpty ? '暂无' : d.typeName}\n'
                  '年份：${d.year.isEmpty ? '暂无' : d.year}\n'
                  '地区：${d.area.isEmpty ? '暂无' : d.area}\n',
                  style: bodyStyle,
                ),
                KotvClickableContent(
                  raw: d.remarks,
                  prefix: '备注：',
                  style: bodyStyle,
                  linkStyle: linkStyle,
                  onOpen: (c) {
                    Navigator.pop(ctx);
                    _openContentFolder(c, siteKey);
                  },
                ),
                const SizedBox(height: 8),
                KotvClickableContent(
                  raw: d.content,
                  style: bodyStyle,
                  linkStyle: linkStyle,
                  onOpen: (c) {
                    Navigator.pop(ctx);
                    _openContentFolder(c, siteKey);
                  },
                ),
              ],
            ),
          ),
        ),
        actions: [
          KotvFocusAction(label: '关闭', color: p.primary, autofocus: true, onPressed: () => Navigator.pop(ctx)),
        ],
      ),
    );
  }

  /// 详情操作按钮设计尺寸；[w] 是上限，一排放不下时由 actionRow 均分。
  ({double w, double h, double icon, double fs, double gap, double inner, double radius})
      _actionMetrics() {
    final compact = KotvLayout.isCompact(context) || KotvLayout.useBottomNav(context);
    final s = LayoutScale.layoutOf(context);
    final ui = compact ? 1.0 : (s < 0.75 ? 0.75 : s);
    return (
      w: (compact ? 48.0 : 72.0) * ui,
      h: (compact ? 36.0 : 56.0) * ui,
      icon: (compact ? 14.0 : 20.0) * ui,
      fs: compact ? 9.0 : 11.0,
      gap: (compact ? 4.0 : 8.0) * ui,
      inner: (compact ? 1.0 : 4.0) * ui,
      radius: (compact ? 7.0 : 10.0) * ui,
    );
  }

  Widget _action(String label, IconData icon, VoidCallback onTap, {required double width}) {
    final p = KotvPalette.of(context);
    final m = _actionMetrics();
    return TvFocus(
      onPressed: onTap,
      borderRadius: m.radius,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          canRequestFocus: false,
          borderRadius: BorderRadius.circular(m.radius),
          child: Ink(
            width: width,
            height: m.h,
            decoration: BoxDecoration(
              color: p.pillBg,
              borderRadius: BorderRadius.circular(m.radius),
              border: Border.all(color: p.pillBorder),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: p.fg, size: m.icon),
                SizedBox(height: m.inner),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: p.fg.withOpacity(0.85), fontSize: m.fs, height: 1.1),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
