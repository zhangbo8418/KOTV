import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import '../api/kotv_engine_url.dart';
import '../desktop/mini_player_window.dart';
import '../player/audio_stage.dart';
import '../player/exo_playback.dart';
import '../player/fvp_playback.dart';
import '../player/html_playback.dart';
import '../player/art_playback.dart';
import '../player/xg_playback.dart';
import '../player/zw_playback.dart';
import '../player/fullscreen_mode.dart';
import '../player/fullscreen_gesture.dart';
import '../player/external_player.dart';
import '../player/kotv_platform.dart';
import '../player/kotv_win_chrome.dart';
import '../player/background_playback.dart';
import '../player/kotv_playback.dart';
import '../player/mini_playback.dart';
import '../player/kotv_player_factory.dart';
import '../player/media_kit_playback.dart';
import '../player/mpv_opts.dart';
import '../player/kotv_win7_direct.dart';
import '../player/playback_settings.dart';
import '../player/native_mpv_playback.dart';
import '../player/play_headers.dart';
import '../player/danmaku_layer.dart';
import '../player/playback_failover.dart';
import '../player/tv_remote_focus.dart';
import '../player/tv_remote_keys.dart';
import '../providers.dart';
import '../api/kotv_settings_cache.dart';
import '../remote/remote_bridge.dart';
import '../theme/kotv_emoji_text.dart';
import '../theme/kotv_palette.dart';
import '../theme/kotv_theme.dart';
import '../theme/stable_focus.dart';
import '../theme/layout_scale.dart';
import '../widgets/auth_gate.dart';
import '../widgets/buffering_overlay.dart';
import '../widgets/cast_flow.dart';
import '../policy/group_policy.dart';
import '../widgets/chrome.dart';
import '../widgets/h_scroll.dart';
import '../widgets/kotv_network_image.dart';
import '../widgets/kotv_step_slider.dart';
import '../widgets/kotv_tv_text_field.dart';
import '../widgets/dialogs.dart';
import '../widgets/focus_arm.dart';
import '../widgets/live_player_chrome.dart';
import '../widgets/marquee_text.dart';
import '../widgets/mini_hover_shell.dart';
import '../widgets/vod_player_chrome.dart';
import 'detail_screen.dart';
import 'shell.dart';

const _liveKeepSep = '\$\$\$';
const _liveFavGroupName = '收藏';
/// 频道栏 / 信息条 / 控件自动隐藏（5s）。
const _liveOverlayHide = kotvPlayerOverlayHide;
const _liveIdleStatus = '确定键打开频道列表 · 菜单键打开底栏 · 点击右侧换源/设置';
/// 回看快进快退步长（10s）。
const _liveCatchupSeekStep = Duration(seconds: 10);

/// 节目条：选中和未选中的透明度亮暗相同。
Color _liveProgramColor(KotvPalette p, {required bool sel, required bool playing}) {
  if (!sel) return p.pillBg.withOpacity(0.7);
  return p.selected.withOpacity(playing ? 0.95 : 0.75);
}

/// 频道行：选中和未选中的透明度亮暗相同。
Color _liveChannelColor(KotvPalette p, {required bool sel}) {
  return sel ? p.selected.withOpacity(0.28) : p.pillBg.withOpacity(0.55);
}

class LiveScreen extends ConsumerStatefulWidget {
  const LiveScreen({super.key});

  /// 切 Tab：await 停掉直播页内全部后端，避免 FVP/HTML 卸树后后台出声。
  static Future<void> prepareLeave() => _LiveScreenState.prepareLeave();

  static bool get isImmersive => _LiveScreenState._active?._immersive == true;

  static void restoreFocusAfterSourcePicker() =>
      _LiveScreenState.restoreFocusAfterSourcePicker();

  @override
  ConsumerState<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends ConsumerState<LiveScreen> with WidgetsBindingObserver {
  static _LiveScreenState? _active;

  static Completer<void>? _leaveDone;

  /// 选源弹窗关闭后拉回页内焦点（部分盒子 PlatformView 会抢走原生焦点）。
  static void restoreFocusAfterSourcePicker() {
    _active?._restoreFocusAfterSourcePicker();
  }

  void _restoreFocusAfterSourcePicker() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (KotvLayout.television) KotvKeyHighlight.arm();
      _remoteFocus.clear();
      if (_rightOpen) {
        _rightFocus.requestFocus();
      } else if (_leftOpen) {
        _focusChannelList();
      } else {
        _focus.requestFocus();
      }
    });
  }

  static Future<void> prepareLeave() async {
    final inFlight = _leaveDone;
    if (inFlight != null) {
      try {
        await inFlight.future.timeout(const Duration(seconds: 5));
      } catch (_) {}
      return;
    }
    final active = _active;
    if (active == null) return;
    final done = Completer<void>();
    _leaveDone = done;
    try {
      if (active._immersive) {
        try {
          await active._exitImmersive();
        } catch (_) {}
      }
      // 等待有上限以便切 Tab；桌面 MPV 拆机仍跑完，再建前等门闩。
      await active._releaseAllBackends().timeout(const Duration(seconds: 8));
    } catch (_) {
    } finally {
      if (!done.isCompleted) done.complete();
      if (_leaveDone == done) {
        _leaveDone = null;
      }
    }
  }

  Player? _mkPlayer;
  KotvPlayback? _mk;
  ExoPlayback? _exo;
  FvpPlayback? _fvp;
  HtmlPlayback? _html;
  ArtPlayback? _art;
  XgPlayback? _xg;
  ZwPlayback? _zw;
  final FocusNode _focus = FocusNode();
  final FocusNode _playFocus = FocusNode(debugLabel: 'live_play');
  final FocusNode _rightFocus = FocusNode(debugLabel: 'live_right');
  final KotvFocusBag _chFocus = KotvFocusBag();
  final KotvFocusBag _progFocus = KotvFocusBag();
  final FocusNode _epgTabFocus = FocusNode(debugLabel: 'live_epg_tab');
  final KotvRemoteFocusMemory _remoteFocus = KotvRemoteFocusMemory();
  /// 焦点停留后切换分类列表（不播台）。
  final KotvFocusArm _groupFocusArm = KotvFocusArm();
  final KotvJumpController _epgScroll = KotvJumpController();
  // 竖屏与全屏面板不会同时出现，分类、频道、节目单各共用一个控制器。
  final KotvJumpController _groupScroll = KotvJumpController();
  final KotvJumpController _channelScroll = KotvJumpController();
  double _groupStride = 42;
  double _channelStride = 52;
  double _epgStride = 36;
  int _pinnedGroup = -999;
  int _pinnedChannel = -999;
  int _pinnedEpg = -999;
  String _zapDigits = '';
  Timer? _zapTimer;

  KotvEmbedBackend get _backend => kotvEmbedBackend(_playerVal);

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

  /// 直播切台：FVP 只 pause；其它与点播硬切同走 [kotvStopPlayersForEpisodeSwitch]（先 pause 再卸文件）。
  Future<void> _stopPlaybackForLiveZap() async {
    final p = _playback;
    if (p is FvpPlayback) {
      await p.pauseForLiveZap();
      return;
    }
    await kotvStopPlayersForEpisodeSwitch([p]);
  }

  KotvPlayback _ensureMpv() {
    if (kotvUsesNativeMpv()) {
      _mk ??= NativeMpvPlayback(opts: _mpvOpts.copyWith(decodeMode: _decodeMode));
      return _mk!;
    }
    // 同步创建；异步起播路径先 [_primeDesktopMpv]。直播须 live:true（关 cache-pause）。
    if (_mk != null) return _mk!;
    if (kotvMpvTeardownStuck) {
      throw StateError('播放器异常，请重启应用');
    }
    _bindDesktopMpv(kotvCreateMpvPlayer());
    return _mk!;
  }

  void _bindDesktopMpv(Player player) {
    _mkPlayer = player;
    _mk = MediaKitPlayback(
      player,
      opts: _mpvOpts.copyWith(decodeMode: _decodeMode),
      live: true,
      onWin7SoftOnDirect: _onWin7SoftOnDirect,
    );
  }

  /// 桌面起播前：等拆机门闩；无实例则 [kotvTakeDesktopMpvPlayer] 再建。
  /// macOS / Android 原生通道不走 media_kit，直接返回。
  /// [kotvMpvTeardownStuck] 时写状态提示重启，返回 false。
  Future<bool> _primeDesktopMpv() async {
    if (kotvUsesNativeMpv()) return true;
    if (kotvMpvTeardownStuck) {
      if (mounted) setState(() => _status = '播放器异常，请重启应用');
      return false;
    }
    final player = await kotvTakeDesktopMpvPlayer(
      alreadyBound: _mk != null && _mkPlayer != null,
      isMounted: () => mounted,
    );
    if (kotvMpvTeardownStuck) {
      if (mounted) setState(() => _status = '播放器异常，请重启应用');
      return false;
    }
    if (player == null) return true;
    if (_mk != null) {
      await kotvDisposeMpvPlayer(player);
      return true;
    }
    _bindDesktopMpv(player);
    return true;
  }

  /// Win7 直出已软解：会话内关直出并换 D3D11 Player（不落盘）。
  void _onWin7SoftOnDirect() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_mpvOpts.direct) return;
      setState(() => _mpvOpts = _mpvOpts.copyWith(direct: false));
      unawaited(() async {
        final pos = _playUrl.isNotEmpty ? _playback.position : Duration.zero;
        await _releaseMpv();
        await _reopenCurrent(pos);
      }());
    });
  }

  /// 卸本页 MPV 会话（经 [kotvReleaseOwnedMpv]）；下次 [_playback] 按当前设置新建。
  Future<void> _releaseMpv() async {
    final mk = _mk;
    final mkPlayer = _mkPlayer;
    if (mk == null && mkPlayer == null) return;
    await kotvReleaseOwnedMpv(
      wrapper: mk,
      desktopPlayer: mkPlayer,
      detach: () {
        _mkPlayer = null;
        _mk = null;
      },
    );
  }

  /// 起播/出画失败：按 [kotvPlanSilentRecover] 拆机 / 换引擎 / 同引擎再建。
  /// `true` = 外层 for continue；`false` = break 后抛错；`null` = 直接结束本次 open。
  Future<bool?> _recoverAfterSilentVideo({
    required KotvPlayback pb,
    required KotvPlaybackFailover failover,
    required int serial,
  }) async {
    bool stale() => !mounted || serial != _playSerial;
    final canRecreateDesktopMpv = !kotvUsesNativeMpv() && pb is MediaKitPlayback;
    final plan = kotvPlanSilentRecover(
      failover: failover,
      canRecreateDesktopMpv: canRecreateDesktopMpv,
    );

    switch (plan.action) {
      case KotvSilentRecoverAction.keepSession:
        return null;
      case KotvSilentRecoverAction.giveUp:
        if (canRecreateDesktopMpv) await _releaseMpv();
        return false;
      case KotvSilentRecoverAction.retrySameEngine:
        if (canRecreateDesktopMpv) await _releaseMpv();
        if (stale()) {
          await kotvStopIfUnowned(pb, [_mk, _fvp, _exo, _html, _art, _xg, _zw]);
          return null;
        }
        return true;
      case KotvSilentRecoverAction.applyStep:
        final step = plan.step!;
        if (canRecreateDesktopMpv) {
          await _releaseMpv();
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
        if (stale()) return null;
        setState(() {
          _playerVal = step.playerVal;
          _decodeMode = step.decodeMode;
          _status = step.status;
        });
        return true;
    }
  }

  /// 切到其它内置后端时停掉闲置引擎。
  /// 调用方须在改 [_playerVal] **之前**调用，以便旧 FVP/Surface 仍在树上时完成 release。
  /// 先 pause 再 stop/release；离开 MPV 时桌面也要 dispose Player，避免双引擎抢 AO。
  Future<void> _stopInactiveBackends(KotvEmbedBackend keep) async {
    if (keep != KotvEmbedBackend.mpv) await _releaseMpv();
    if (keep != KotvEmbedBackend.fvp) {
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

  /// 切 Tab / 离开直播：soft pause → release → 卸视图 → dispose。
  Future<void> _releaseAllBackends() async {
    // 作废进行中的起播：否则 livePlay 返回后会经 [_playback] 新建一个无人管的播放器。
    _playSerial++;
    _unwireLivePlaybackErrors();
    _unwireLivePlaybackEnded();

    final fvp = _fvp;
    final mk = _mk;
    final exo = _exo;
    final html = _html;
    final art = _art;
    final xg = _xg;
    final zw = _zw;
    final mkPlayer = _mkPlayer;
    final backends = <KotvPlayback?>[fvp, mk, exo, html, art, xg, zw];

    await kotvSoftPausePlayers(backends);
    // release 完成（含 FVP Surface：dispose 内先清 native 面再删 mdk）后再清 _playUrl。
    await kotvHardReleasePlayers(backends, waitFirst: fvp);

    _fvp = null;
    _mk = null;
    _exo = null;
    _html = null;
    _art = null;
    _xg = null;
    _zw = null;
    _mkPlayer = null;
    _playUrl = '';
    _playDirect = '';
    if (mounted) {
      setState(() {});
      await WidgetsBinding.instance.endOfFrame;
    }

    await kotvDisposeMpvPlayer(mkPlayer);
    kotvDisposePlaybackWrappers(backends);
    _releasedHard = true;
  }

  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _sources = [];
  List<Map<String, dynamic>> _groups = [];
  final Set<int> _unlocked = {};
  List<Map<String, dynamic>> _epgDays = [];
  List<Map<String, dynamic>> _programs = [];
  int _srcIdx = 0;
  int _groupIdx = 0;
  int _chIdx = -1;
  /// 正在播的分类和频道。浏览其它分类时 [_chIdx] 会空着，切回来再恢复。
  int _playGroupIdx = -1;
  int _playChIdx = -1;
  /// 每个分组上次选中的频道名。收藏组重排或换源后按下标会指错台。
  final Map<String, String> _groupChannelPos = {};
  String _playGroupName = '';
  String _playChName = '';
  DateTime? _liveBackUntil;
  bool _liveBackConsumed = false;
  int _dayIdx = 0;
  int _line = 0;
  int _lines = 1;
  String _lineName = '';
  bool _leftOpen = false;
  bool _rightOpen = false;
  /// 横屏左侧节目单列；默认收起，避免挡画面 / 撑破面板。
  bool _epgOpen = false;
  /// 回看底栏播控；直播不用。
  bool _chromeVisible = false;
  /// 换台后短暂频道信息条（不等于播控）。
  bool _channelInfoVisible = false;
  bool _catchup = false;
  bool _catchupChrome = false;
  /// 当前回看的节目下标；-1 表示未在回看。
  int _catchupProgIdx = -1;
  bool _miniDesktop = false;
  /// 沉浸全屏：复用 PC 左右菜单交互（不再推另一套点播式全屏页）。
  bool _immersive = false;
  KotvDesktopFullscreenKind _desktopFs = KotvDesktopFullscreenKind.window;
  /// 竖屏/横屏/沉浸全屏共用同一块 PlatformView/Texture。
  final GlobalKey _videoHostKey = GlobalKey(debugLabel: 'kotv_live_video');
  /// 竖屏面板：0=频道 1=EPG
  int _portraitTab = 0;
  /// 竖屏播放器底栏显隐（点画面切换；数秒后自动隐藏）
  bool _portraitChrome = true;
  String _status = _liveIdleStatus;
  String _title = '选择频道开始播放';
  String _decodeMode = 'auto';
  String _prefDecodeMode = 'auto';
  String _renderMode = 'surface';
  KotvMpvOpts _mpvOpts = const KotvMpvOpts();
  String _playerVal = kotvDefaultLivePlayer();
  String _prefPlayerVal = kotvDefaultLivePlayer();
  String _prefPlayerFailover = 'auto';
  /// 播失败自动切下一线路（默认开）。
  bool _liveAutoChange = true;
  /// 起播超时（秒）。源未写时 15。
  int _livePlayTimeoutSec = 15;
  bool _liveAcross = true;
  bool _liveInvert = false;

  /// 沉浸画面手势（非电视）：亮/音/回看 seek/中区甩动换台。
  KotvFsMode _liveGMode = KotvFsMode.none;
  KotvSideGestureSession? _liveSideGesture;
  Duration? _liveSeekPreviewBase;
  Duration _liveSeekPreviewDelta = Duration.zero;
  int? _liveSwipePointer;
  Offset? _liveSwipeDownAt;
  final Map<int, Offset> _livePointers = {};
  double _livePinchScale = 1.0;
  double _livePinchStartScale = 1.0;
  double _livePinchSpan0 = 1;
  Offset _livePinchFocal = Offset.zero;
  Timer? _liveWheelHudTimer;
  DateTime? _liveLastTapAt;
  String _liveScale = 'default';
  AspectSpec _liveAspect = const AspectSpec(key: 'default', fit: BoxFit.contain);
  /// off | audio | pip
  String _playerBackground = 'pip';
  int _playSerial = 0;
  int _epgSerial = 0;
  String _playUrl = '';
  /// 引擎下发的可直开 CDN（空则只能开 [_playUrl]）。
  String _playDirect = '';
  /// 遥控即时弹幕（直播页无弹幕设置 UI，仅接收展示）。
  final ValueNotifier<List<DanmakuItem>> _danmakuItems = ValueNotifier(const []);
  /// [_releaseAllBackends] 已跑完则 dispose 不再二次硬拆。
  bool _releasedHard = false;
  Map<String, String>? _playHeaders;
  Map<String, dynamic>? _playDrm;
  Timer? _catchupHideTimer;
  /// 长按收藏的频道名（跨源持久化；灌入「收藏」组）。
  final Set<String> _favNames = {};
  Timer? _portraitHideTimer;
  Timer? _cursorHideTimer;
  MouseCursor _mouseCursor = SystemMouseCursors.basic;
  bool _pointerAtBottom = false;
  /// 指针停在左频道栏 / 右设置栏内（悬停不计时隐藏）。
  bool _pointerInLeftPanel = false;
  bool _pointerInRightPanel = false;
  RemoteBridge? _boundRemote;
  KotvPlayback? _errorWiredPb;
  VoidCallback? _playbackErrorListener;
  StreamSubscription<bool>? _endedSub;
  bool _failSwitchBusy = false;
  bool _endedBusy = false;
  bool _pickingPlayer = false;

  void _onLiveGlobalFocus() {
    if (!mounted || !_liveUiOpen) return;
    if (_livePopupOpen()) return;
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null || identical(primary, _focus)) return;
    final ctx = primary.context;
    if (ctx == null) return;
    // 勿记住弹窗 / 其它路由上的节点，否则关窗 restore 打到已卸树焦点。
    if (ctx.findAncestorStateOfType<_LiveScreenState>() != this) return;
    _remoteFocus.remember(primary);
  }

  void _restoreLiveRemoteFocus() {
    _bumpLiveChrome();
    if (_catchup && _catchupChrome) {
      _remoteFocus.restore(fallback: () {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _catchupChrome) _playFocus.requestFocus();
        });
      });
      return;
    }
    if (_rightOpen) {
      _remoteFocus.restore(fallback: () {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _rightOpen) _rightFocus.requestFocus();
        });
      });
      return;
    }
    if (_leftOpen) {
      _remoteFocus.restore(fallback: () {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _leftOpen) _focusChannelList();
        });
      });
      return;
    }
    _showLiveChromeAndFocusPlay();
  }

  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    FocusManager.instance.addListener(_onLiveGlobalFocus);
    _active = this;
    liveScreenHandleBack = _handleLiveBack;
    kotvRegisterQuitHook(_prepareQuit);
    MiniPlayerWindow.onAndroidPipChanged = (inPip) {
      if (!mounted) return;
      setState(() {
        _miniDesktop = inPip;
        if (_catchup) _catchupChrome = inPip;
      });
    };
    _bootstrap();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _attachRemoteHandlers();
      if (KotvWinChrome.isNeeded) {
        _winChromeToken = KotvWinChrome.bind(_onWinChromeEvent);
        _danmakuItems.addListener(_syncWinChrome);
        KotvWinChrome.imagesReady.addListener(_syncWinChrome);
        _syncWinChrome();
      }
    });
  }

  int _winChromeToken = 0;
  /// Win7：直播画面区（横屏整页 / 竖屏 16:9 框）锚点，原生壳按它摆面板与手势层。
  final GlobalKey _winLiveSurfaceKey = GlobalKey(debugLabel: 'kotv_live_surface');
  bool _winSyncQueued = false;
  /// 后端切换会换 [_playback] 实例；监听跟着当前实例走。
  KotvPlayback? _winListened;
  String? _lastWinLiveSnap;
  late final KotvWinBufferText _winBuffer = KotvWinBufferText(_syncWinChrome);
  /// 竖屏画面单击延迟（等双击判定）与按下点。
  Timer? _winPortraitTapTimer;
  Offset? _winPortraitDownAt;

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _syncWinChrome();
  }

  bool get _winPortrait =>
      !_immersive && (KotvLayout.useBottomNav(context) || KotvLayout.isCompact(context));

  Rect? _winLiveSurface() {
    final box = _winLiveSurfaceKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || !box.attached) return null;
    try {
      return box.localToGlobal(Offset.zero) & box.size;
    } catch (_) {
      return null;
    }
  }

  /// 底栏 / 右栏按钮操作后：同 [LiveCatchupChrome] onBump 重排隐藏计时。
  void _winBump() {
    if (_winPortrait) {
      _pulsePortraitChrome();
    } else {
      _bumpLiveChrome();
    }
  }

  void _onWinChromeEvent(Map<String, dynamic> e) {
    if (!mounted) return;
    switch (e['type'] as String? ?? '') {
      case 'pointer':
        _onWinLivePointer(e);
        break;
      case 'pointerHold':
        final on = e['on'] == true;
        _pointerInLeftPanel = on && _leftOpen;
        _pointerInRightPanel = on && _rightOpen;
        if (_catchup && _catchupChrome) _pointerAtBottom = on;
        if (on) {
          _cancelHideOverlays();
          _catchupHideTimer?.cancel();
          _keepMouseVisible();
        } else if (_catchup) {
          _pulseCatchupChrome();
        } else {
          _scheduleHideOverlays();
        }
        break;
      case 'key':
        final ke = KotvWinChrome.keyEventFromMap(e);
        if (ke != null) _onKey(FocusManager.instance.primaryFocus ?? _focus, ke);
        break;
      case 'group':
        final idx = (e['index'] as num?)?.toInt() ?? -1;
        if (idx >= 0 && idx < _groups.length) {
          _cancelHideOverlays();
          unawaited(_selectGroup(idx));
        }
        break;
      case 'channel':
        final idx = (e['index'] as num?)?.toInt() ?? -1;
        if (idx >= 0 && idx < _channels.length) _selectChannelFromList(idx);
        break;
      case 'channelFav':
        final idx = (e['index'] as num?)?.toInt() ?? -1;
        if (idx >= 0 && idx < _channels.length) unawaited(_toggleChannelFav(idx));
        break;
      case 'epgDay':
        final idx = (e['index'] as num?)?.toInt() ?? -1;
        if (idx >= 0 && idx < _epgDays.length) _selectEpgDay(idx, resetHide: true);
        break;
      case 'epg':
        final idx = (e['index'] as num?)?.toInt() ?? -1;
        if (idx >= 0 && idx < _programs.length) {
          _cancelHideOverlays();
          if (_programs[idx]['catchup'] == true) unawaited(_playCatchup(idx));
        }
        break;
      case 'epgToggle':
        _cancelHideOverlays();
        final open = e['open'] == true;
        setState(() => _epgOpen = open);
        if (open && _programs.isEmpty && _chIdx >= 0) unawaited(_loadEpg());
        if (open) _scheduleScrollEpgToHighlight();
        break;
      case 'liveRight':
        _onWinLiveRight(e['id'] as String? ?? '');
        break;
      case 'slider':
        if (e['id'] != 'volume') break;
        final v = ((e['value'] as num?)?.toDouble() ?? 50).round().clamp(1, 100);
        unawaited(_playback.setVolume(v.toDouble()));
        if (e['commit'] == true) {
          _winBump();
          unawaited(_persistLiveSetting('playerVolume', '$v').catchError((_) {}));
        }
        break;
      case 'seekFraction':
        if (e['commit'] != true) break;
        final dur = _playback.duration;
        if (dur > Duration.zero) {
          final frac = ((e['value'] as num?)?.toDouble() ?? 0).clamp(0.0, 1.0);
          unawaited(_playback.seek(Duration(milliseconds: (dur.inMilliseconds * frac).round())));
        }
        _winBump();
        break;
      case 'toggle':
        _winBump();
        unawaited(_playback.playOrPause());
        break;
      case 'cast':
        _winBump();
        unawaited(_cast());
        break;
      case 'mini':
        unawaited(_miniDesktop ? _exitMini() : _enterMini());
        break;
      case 'pill':
        if (_catchup && _catchupChrome && !_immersive) {
          unawaited(_exitCatchup());
        } else {
          unawaited(_exitImmersive());
        }
        break;
      case 'sheet':
        unawaited(_onWinLiveSheet(e['id'] as String? ?? '', e['kind'] as String? ?? ''));
        break;
      case 'pickPlayer':
        unawaited(_winApplyPickedPlayer(e['id'] as String? ?? ''));
        break;
      case 'back':
        kotvHandleAppBack?.call();
        break;
    }
  }

  /// 原生手势层指针 → 与 Flutter 画面 Listener / MouseRegion 相同的处理。
  void _onWinLivePointer(Map<String, dynamic> e) {
    final rect = _winLiveSurface();
    if (rect == null) return;
    final phase = e['phase'] as String? ?? '';
    final c = BoxConstraints.tight(rect.size);
    if (phase == 'scroll') {
      if (_winPortrait) return;
      final pos = Offset((e['x'] as num?)?.toDouble() ?? 0, (e['y'] as num?)?.toDouble() ?? 0);
      final dpr = MediaQuery.devicePixelRatioOf(context);
      _onLiveFsPointerSignal(PointerScrollEvent(
        kind: PointerDeviceKind.mouse,
        position: pos,
        scrollDelta: Offset(
          ((e['dx'] as num?)?.toDouble() ?? 0) / dpr,
          ((e['dy'] as num?)?.toDouble() ?? 0) / dpr,
        ),
      ));
      return;
    }
    final ev = KotvWinChrome.pointerEvent(e, origin: rect.topLeft);
    if (ev == null) return;
    if (ev is PointerHoverEvent) {
      _onLivePointerMove(ev, c, sides: !_winPortrait, portrait: _winPortrait);
      return;
    }
    if (ev is PointerExitEvent) {
      _onLivePointerExit();
      return;
    }
    if (_winPortrait) {
      _onWinPortraitPointer(ev);
      return;
    }
    if (ev is PointerDownEvent) {
      _onLiveFsPointerDown(ev);
    } else if (ev is PointerMoveEvent) {
      _onLiveFsPointerMove(ev);
    } else if (ev is PointerUpEvent) {
      _onLiveFsPointerUp(ev);
    } else if (ev is PointerCancelEvent) {
      _onLiveFsPointerCancel(ev);
    }
  }

  /// 竖屏画面 GestureDetector：单击显隐回看底栏，双击全屏。
  void _onWinPortraitPointer(PointerEvent ev) {
    if (ev is PointerDownEvent) {
      _winPortraitDownAt = ev.position;
      return;
    }
    if (ev is PointerCancelEvent) {
      _winPortraitDownAt = null;
      return;
    }
    if (ev is! PointerUpEvent) return;
    final down = _winPortraitDownAt;
    _winPortraitDownAt = null;
    if (down == null || (ev.position - down).distance > kTouchSlop) return;
    if (_winPortraitTapTimer?.isActive ?? false) {
      _winPortraitTapTimer!.cancel();
      _winPortraitTapTimer = null;
      _onLiveDoubleTap();
      return;
    }
    _winPortraitTapTimer = Timer(kDoubleTapTimeout, () {
      _winPortraitTapTimer = null;
      if (mounted) _togglePortraitChrome();
    });
  }

  /// 右栏药丸 / 回看底栏文字钮（与 Flutter 右栏 onTap 同序同义）。
  void _onWinLiveRight(String id) {
    switch (id) {
      case 'prevCh':
        if (_channels.isEmpty) return;
        unawaited(_stepChannel(delta: _liveInvert ? 1 : -1));
        break;
      case 'nextCh':
        if (_channels.isEmpty) return;
        unawaited(_stepChannel(delta: _liveInvert ? -1 : 1));
        break;
      case 'line':
        if (_chIdx < 0 || _lines <= 1) return;
        _playChannel(_chIdx, line: (_line + 1) % _lines);
        break;
      case 'epg':
        unawaited(_loadEpg());
        break;
      case 'cast':
        unawaited(_cast());
        break;
      case 'scale':
        _winBump();
        unawaited(_cycleLiveScale());
        break;
      case 'across':
        _winBump();
        _onLiveAcross();
        break;
      case 'invert':
        _winBump();
        _onLiveInvert();
        break;
      case 'failSwitch':
        _winBump();
        _onLiveFailSwitch();
        break;
      case 'mini':
        unawaited(_enterMini());
        break;
      case 'fullscreen':
        _winBump();
        unawaited(_toggleLiveFullscreen());
        break;
      case 'player':
        _winBump();
        unawaited(_pickPlayer());
        break;
      case 'decode':
        _winBump();
        unawaited(_pickDecode());
        break;
      case 'direct':
        _winBump();
        unawaited(_toggleDirectOutput());
        break;
      case 'render':
        unawaited(_pickRender());
        break;
      case 'settings':
        goKotvPage(ref, KotvPage.settings);
        break;
      case 'configureSources':
        unawaited(() async {
          await showLivePicker(context, ref);
          await _bootstrap(forceLoad: true);
        }());
        break;
      case 'close':
        setState(() => _rightOpen = false);
        break;
      default:
        if (id.startsWith('source:')) {
          final i = int.tryParse(id.substring(7)) ?? -1;
          if (i >= 0 && i < _sources.length) {
            _loadSource(i, autoPlay: true, force: _sources.length == 1 || i == _srcIdx);
          }
        }
    }
  }

  Future<void> _onWinLiveSheet(String id, String kind) async {
    if (id.isEmpty) return;
    switch (kind) {
      case 'player':
        await _winApplyPickedPlayer(id);
        break;
      case 'decode':
        await _applyDecode(id);
        break;
      case 'render':
        await _applyRender(id);
        break;
    }
  }

  Future<void> _winApplyPickedPlayer(String id) async {
    if (id.isEmpty) return;
    await _applyPickedPlayer(kotvClampPlayerVal(id, live: true));
  }

  /// 直播设置右栏条目（[_buildLiveRightPanel] 同序：标题、药丸、音量、直播源）。
  List<Map<String, dynamic>> _winLiveRightItems(bool land, double ui) {
    Map<String, dynamic> pill(String id, String label, {String sub = '', bool selected = false}) =>
        KotvWinChrome.row(id: id, label: label, kind: 'pill', sub: sub, selected: selected);
    Map<String, dynamic> gap(double v) => KotvWinChrome.row(kind: 'gap', label: '', value: v);
    return [
      KotvWinChrome.row(kind: 'title', label: '直播设置'),
      gap(land ? 8 : 12),
      pill('prevCh', '上一频道'),
      gap(8),
      pill('nextCh', '下一频道'),
      gap(8),
      pill('line', '换线路 (${_line + 1}/$_lines)'),
      gap(8),
      pill('epg', '刷新 EPG'),
      gap(8),
      pill('cast', '投屏'),
      gap(8),
      pill('scale', '画面比例 · ${_liveScaleLabel(_liveScale)}'),
      gap(8),
      pill('across', '跨组换台 · ${_liveAcross ? '开' : '关'}'),
      gap(8),
      pill('invert', '反转换台 · ${_liveInvert ? '开' : '关'}'),
      gap(8),
      pill('failSwitch', '失败换线 · ${_liveAutoChange ? '开' : '关'}'),
      gap(8),
      pill('mini', '迷你桌面播放'),
      gap(8),
      pill('fullscreen', _immersive ? '退出全屏' : '全屏观看'),
      gap(8),
      if (kotvCanSwitchPlayer(live: true)) ...[
        pill('player', '播放器 · ${flutterPlayerLabel(_playerVal)}'),
        gap(8),
      ],
      pill('decode', '解码 · $_decodeLabel'),
      if (_showDirectOutput) ...[
        gap(8),
        pill('direct', '硬解直出 · ${_playback.directOutputActive ? '开' : '关'}'),
      ],
      if (kotvPlayerRenderApplies(_playerVal)) ...[
        gap(8),
        pill('render', '渲染 · ${kotvPlayerRenderLabel(_renderMode)}'),
      ],
      gap(8),
      KotvWinChrome.row(id: 'volume', kind: 'slider', label: '音量', min: 1, max: 100, divisions: 99),
      gap(8),
      pill('settings', '打开设置页'),
      gap(16),
      KotvWinChrome.row(kind: 'label', label: '直播源'),
      gap(8),
      for (var i = 0; i < _sources.length; i++) ...[
        pill(
          'source:$i',
          _sources.length == 1 ? '刷新' : '${_sources[i]['name'] ?? _sources[i]['url']}',
          sub: _sources.length > 1 && (_sources[i]['current'] == true || i == _srcIdx) ? '（当前）' : '',
          selected: i == _srcIdx,
        ),
        gap(6),
      ],
      gap(12),
      pill('configureSources', '配置直播源'),
      gap(8),
      pill('close', '关闭面板'),
    ];
  }

  /// 直播 HUD：亮度/音量拖动、回看快进退预览（与 Flutter 画面中心浮层同文案）。
  Map<String, dynamic> _winLiveHud() {
    final side = _liveSideGesture;
    if (side != null) {
      return KotvWinChrome.hud(
        kind: 'side',
        text: '${side.percent.round()}%',
        icon: side.kind == 'bright' ? 'bright' : 'volume',
        ui: false,
      );
    }
    if (_liveSeekPreviewBase != null) {
      return KotvWinChrome.hud(
        kind: 'seek',
        text: '${fmtBoundedPlayerTime(_liveSeekPreviewTarget)} / ${fmtBoundedPlayerTime(_playback.duration)}',
        icon: _liveSeekPreviewDelta >= Duration.zero ? 'ff' : 'rew',
        ui: false,
      );
    }
    return KotvWinChrome.hud();
  }

  /// 下一微任务合并推送（setState / 播放态频繁变化）。
  void _syncWinChrome() {
    if (!KotvWinChrome.isNeeded || _winSyncQueued) return;
    _winSyncQueued = true;
    scheduleMicrotask(() {
      _winSyncQueued = false;
      _pushWinChrome();
    });
  }

  void _pushWinChrome() {
    if (!KotvWinChrome.isNeeded || !mounted || _winChromeToken == 0) return;
    final surface = _winLiveSurface();
    final p = _playback;
    if (!identical(p, _winListened)) {
      try {
        _winListened?.removeListener(_syncWinChrome);
      } catch (_) {}
      _winListened = p;
      p.addListener(_syncWinChrome);
    }
    final busy = _loading || _status.contains('解析') || _status.contains('加载') || _status.contains('缓冲');
    final Map<String, dynamic> fields;
    if (_miniDesktop) {
      fields = {'mode': 'mini', 'miniKind': 'live', 'catchupSeek': _catchup};
    } else if (surface == null) {
      fields = {'mode': ''};
    } else {
      final portrait = _winPortrait;
      final land = KotvLayout.isLandscapeCompact(context);
      final ui = LayoutScale.grow(context);
      final sideOpen = !portrait && (_leftOpen || _rightOpen);
      final catchupBar = portrait ? _catchup && (_portraitChrome || _catchupChrome) : _catchup && _catchupChrome;
      var pill = '';
      if (!portrait && !sideOpen) {
        if (_catchup && _catchupChrome) {
          pill = _immersive ? '退出全屏' : '返回直播';
        } else if (!_catchup && _immersive && _channelInfoVisible) {
          pill = '退出全屏';
        }
      }
      final highlight = _epgHighlightIndex();
      final dpr = MediaQuery.devicePixelRatioOf(context);
      final logoW = (land ? 28.0 : 40.0) * ui;
      fields = {
        'mode': 'live',
        'surfaceScreen': {
          'left': surface.left,
          'top': surface.top,
          'width': surface.width,
          'height': surface.height,
        },
        'immersive': _immersive,
        'liveLeftVisible': !portrait && _leftOpen,
        'liveRightVisible': !portrait && _rightOpen,
        'channelVisible': !portrait && _channelInfoVisible && (!_catchup || !_catchupChrome),
        'catchupBar': catchupBar,
        'catchupSeek': _catchup,
        'pillLabel': pill,
        'centerVisible': _catchup && _playUrl.isNotEmpty && !sideOpen && !busy && !p.playing && !p.stalling,
        'zapDigits': portrait ? '' : _zapDigits,
        'liveError': _error ?? '',
        'groups': [
          for (var i = 0; i < _groups.length; i++)
            KotvWinChrome.row(label: '${_groupLocked(i) ? '🔒 ' : ''}${_groups[i]['name'] ?? ''}'),
        ],
        'groupSelected': _groupIdx,
        'channels': [
          for (var i = 0; i < _channels.length; i++)
            KotvWinChrome.row(
              label: '${_channels[i]['name'] ?? ''}',
              trailing: _channelNumberLabel(_channels[i], i),
              icon: () {
                final key = KotvWinChrome.logoKey('${_channels[i]['logo'] ?? ''}', width: logoW, dpr: dpr);
                return key.isEmpty ? '' : 'img:$key';
              }(),
            ),
        ],
        'channelSelected': _chIdx,
        'channelDigits': _channelNumDigitsFor(_channels),
        'epgDays': [
          for (var i = 0; i < _epgDays.length; i++)
            () {
              final d = '${_epgDays[i]['date'] ?? 'D$i'}';
              return d.length >= 10 ? d.substring(5, 10) : d;
            }(),
        ],
        'epgDaySelected': _dayIdx,
        'programs': [
          for (var i = 0; i < _programs.length; i++)
            () {
              final prog = _programs[i];
              final playing = _catchup && i == _catchupProgIdx;
              final canCatchup = prog['catchup'] == true;
              final title = '${prog['title'] ?? ''}'.trim();
              final label = title.isNotEmpty ? title : '${prog['label'] ?? ''}'.trim();
              return KotvWinChrome.row(
                label: '$label${playing ? ' · 回看中' : (canCatchup ? ' · 回看' : '')}',
                trailing: '${prog['start'] ?? ''}'.trim(),
                selected: playing || (!_catchup && prog['now'] == true),
                on: playing,
              );
            }(),
        ],
        'programSelected': highlight,
        'epgOpen': _epgOpen,
        'liveRightItems': _winLiveRightItems(land, ui),
        'channelNo': _channelNum,
        'channelName': _title,
        'channelLogo': KotvWinChrome.logoKey(_currentLogo, width: 48, dpr: dpr),
        'programTime': _programTimeLabel,
        'programTitle': _programTitleLabel.isNotEmpty ? _programTitleLabel : _status,
        'lineLabel': _lineLabel,
        ..._winLiveHud(),
      };
    }
    final all = <String, dynamic>{
      ...KotvWinChrome.metrics(context),
      ...KotvWinChrome.playbackFields(p, forceBuffering: busy),
      ...fields,
      // 同横竖屏 KotvBufferingOverlay(force: busy)；迷你窗不画。
      'bufferText': _miniDesktop || surface == null ? _winBuffer.label(null) : _winBuffer.label(p, force: busy),
      'gestures': _livePlayerGestures,
      'hasCast': true,
      'hasMini': true,
      'catchupScale': _liveScaleLabel(_liveScale).trim().isEmpty ? '比例' : _liveScaleLabel(_liveScale),
      'catchupPlayer': kotvCanSwitchPlayer(live: true)
          ? flutterPlayerLabel(_playerVal.trim().isEmpty ? kotvDefaultLivePlayer() : _playerVal)
          : '',
      'catchupDecode': _decodeLabel,
      'catchupDirect': _showDirectOutput ? (_playback.directOutputActive ? '直出开' : '直出关') : '',
      'catchupAcross': _liveAcross ? '跨组开' : '跨组关',
      'catchupInvert': _liveInvert ? '反转开' : '反转关',
      'catchupFail': _liveAutoChange ? '换线开' : '换线关',
    };
    all['positionSec'] = ((all['positionSec'] as double) * 4).roundToDouble() / 4;
    all['bufferedSec'] = ((all['bufferedSec'] as double) * 4).roundToDouble() / 4;
    final items = _danmakuItems.value;
    unawaited(KotvWinChrome.setDanmaku(enabled: items.isNotEmpty, items: items));
    final snap = all.toString();
    if (snap == _lastWinLiveSnap) return;
    _lastWinLiveSnap = snap;
    unawaited(KotvWinChrome.update(all));
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

  void _syncAndroidAutoPip() {
    final wantPip = _playerBackground == 'pip' && _playUrl.isNotEmpty;
    unawaited(MiniPlayerWindow.setAndroidAutoEnter(this, wantPip));
  }

  Future<void> _prepareQuit() async {
    try {
      await _releaseAllBackends();
    } catch (_) {}
  }

  @override
  void dispose() {
    _playSerial++;
    WidgetsBinding.instance.removeObserver(this);
    FocusManager.instance.removeListener(_onLiveGlobalFocus);
    _detachRemoteHandlers();
    if (_active == this) _active = null;
    kotvUnregisterQuitHook(_prepareQuit);
    liveScreenHandleBack = null;
    if (KotvWinChrome.isNeeded) {
      _danmakuItems.removeListener(_syncWinChrome);
      KotvWinChrome.imagesReady.removeListener(_syncWinChrome);
      _winBuffer.dispose();
      try {
        _winListened?.removeListener(_syncWinChrome);
      } catch (_) {}
      _winListened = null;
      _winPortraitTapTimer?.cancel();
      KotvWinChrome.unbind(_winChromeToken);
      _winChromeToken = 0;
    }
    MiniPlayerWindow.onAndroidPipChanged = null;
    unawaited(MiniPlayerWindow.setAndroidAutoEnter(this, false));
    if (_miniDesktop) {
      unawaited(MiniPlayerWindow.exit());
    }
    if (_immersive && !kotvIsDesktop()) {
      unawaited(kotvExitSystemFullscreen(wasDisplayFullscreen: false));
    }
    _hideTimer?.cancel();
    _catchupHideTimer?.cancel();
    _portraitHideTimer?.cancel();
    _cursorHideTimer?.cancel();
    _liveWheelHudTimer?.cancel();
    _groupFocusArm.dispose();
    _unwireLivePlaybackErrors();
    _unwireLivePlaybackEnded();
    _remoteFocus.clear();
    _focus.dispose();
    _playFocus.dispose();
    _rightFocus.dispose();
    _chFocus.dispose();
    _progFocus.dispose();
    _epgTabFocus.dispose();
    _epgScroll.dispose();
    _groupScroll.dispose();
    _channelScroll.dispose();
    _zapTimer?.cancel();
    _danmakuItems.dispose();
    // 正常路径已在 [_releaseAllBackends]；异常路径尽量先 release 再 dispose 包装类。
    if (!_releasedHard) {
      final fvp = _fvp;
      final mk = _mk;
      final exo = _exo;
      final html = _html;
      final art = _art;
      final xg = _xg;
      final zw = _zw;
      final mkPlayer = _mkPlayer;
      final backends = <KotvPlayback?>[fvp, mk, exo, html, art, xg, zw];
      _fvp = null;
      _mk = null;
      _exo = null;
      _html = null;
      _art = null;
      _xg = null;
      _zw = null;
      _mkPlayer = null;
      _playUrl = '';
      _playDirect = '';
      unawaited(() async {
        await kotvHardReleasePlayers(backends, waitFirst: fvp);
        await kotvDisposeMpvPlayer(mkPlayer);
        kotvDisposePlaybackWrappers(backends);
      }());
    }
    super.dispose();
  }

  void _attachRemoteHandlers() {
    final bridge = ref.read(remoteBridgeProvider);
    if (bridge == null) return;
    _boundRemote = bridge;
    bridge.onControl = _onRemoteControl;
    bridge.onSubtitleFile = _onRemoteSubtitle;
    bridge.onLiveRefresh = _onRemoteLiveRefresh;
    bridge.onLiveDanmaku = _onRemoteLiveDanmaku;
    bridge.onPlayerRefresh = _onRemotePlayerRefresh;
  }

  void _detachRemoteHandlers() {
    final bridge = _boundRemote;
    _boundRemote = null;
    if (bridge == null) return;
    if (identical(bridge.onControl, _onRemoteControl)) bridge.onControl = null;
    if (identical(bridge.onSubtitleFile, _onRemoteSubtitle)) bridge.onSubtitleFile = null;
    if (identical(bridge.onLiveRefresh, _onRemoteLiveRefresh)) bridge.onLiveRefresh = null;
    if (identical(bridge.onLiveDanmaku, _onRemoteLiveDanmaku)) bridge.onLiveDanmaku = null;
    if (identical(bridge.onPlayerRefresh, _onRemotePlayerRefresh)) bridge.onPlayerRefresh = null;
  }

  void _onRemotePlayerRefresh() {
    if (!mounted || _groups.isEmpty) return;
    unawaited(_playChannel(_chIdx, line: _line));
  }

  void _onRemoteLiveDanmaku(DanmakuItem item) {
    if (!mounted) return;
    _danmakuItems.value = kotvAppendLiveDanmaku(_danmakuItems.value, item, _playback.position);
    if (KotvWinChrome.isNeeded) _syncWinChrome();
  }

  Widget _buildLiveDanmakuOverlay() {
    // Win7：弹幕由进程内原生壳绘制；与 macOS/Win8+ Flutter DanmakuOverlay 隔离。
    if (KotvWinChrome.isNeeded) return const SizedBox.shrink();
    return ValueListenableBuilder<List<DanmakuItem>>(
      valueListenable: _danmakuItems,
      builder: (context, items, _) {
        if (items.isEmpty) return const SizedBox.shrink();
        return DanmakuOverlay(
          enabled: true,
          player: _playback,
          items: items,
        );
      },
    );
  }

  void _onRemoteLiveRefresh() {
    if (!mounted || _sources.isEmpty) return;
    final i = _srcIdx.clamp(0, _sources.length - 1);
    unawaited(_loadSource(i, autoPlay: true, force: true));
  }

  void _onRemoteControl(String type, int seekMs) {
    if (!mounted) return;
    final t = type.trim().toLowerCase();
    switch (t) {
      case 'prev':
        unawaited(_stepChannel(delta: _liveInvert ? 1 : -1));
        break;
      case 'next':
        unawaited(_stepChannel(delta: _liveInvert ? -1 : 1));
        break;
      case 'replay':
        if (_playUrl.isEmpty || !_catchup) return;
        unawaited(() async {
          await _playback.seek(Duration.zero);
          await _playback.play();
        }());
        break;
      case 'play':
        if (_playUrl.isEmpty) return;
        unawaited(_playback.play());
        break;
      case 'pause':
        if (_catchup) unawaited(_playback.pause());
        break;
      case 'toggle':
      case 'playpause':
      case 'play_pause':
        if (_catchup) {
          unawaited(_playback.playOrPause());
        } else {
          _flashChannelInfo();
        }
        break;
      case 'seek':
        if (!_catchup || _playUrl.isEmpty) return;
        if (seekMs > 0) {
          unawaited(_playback.seek(Duration(milliseconds: seekMs)));
        }
        break;
      case 'forward':
      case 'forward10':
        if (!_catchup || _playUrl.isEmpty) return;
        final ms = seekMs > 0 ? seekMs : 10000;
        unawaited(_playback.seek(_playback.position + Duration(milliseconds: ms)));
        break;
      case 'backward':
      case 'rewind':
      case 'back10':
        if (!_catchup || _playUrl.isEmpty) return;
        final ms = seekMs > 0 ? seekMs : 10000;
        final next = _playback.position - Duration(milliseconds: ms);
        unawaited(_playback.seek(next.isNegative ? Duration.zero : next));
        break;
      case 'stop':
        unawaited(_releaseAllBackends());
        break;
    }
  }

  void _onRemoteSubtitle(String path) {
    if (!mounted) return;
    unawaited(_playback.addSubtitlePath(path));
  }

  bool _livePopupOpen() {
    if (kotvHasTopPopup(rootNavigatorKey.currentState)) return true;
    if (!mounted) return false;
    return kotvHasTopPopup(Navigator.of(context, rootNavigator: false));
  }

  bool _popLivePopup() {
    if (kotvPopTopPopup(rootNavigatorKey.currentState)) return true;
    if (!mounted) return false;
    return kotvPopTopPopup(Navigator.of(context, rootNavigator: false));
  }

  /// 返回一次只关一层：弹窗、右设置、左频道栏、信息条或回看播控，然后才退出回看或全屏。
  /// 同一按键会打到本页 Focus 和外壳，短时间内第二次调用沿用第一次的结果。
  bool _handleLiveBack() {
    final now = DateTime.now();
    final until = _liveBackUntil;
    if (until != null && now.isBefore(until)) return _liveBackConsumed;
    _liveBackUntil = now.add(const Duration(milliseconds: 400));
    final consumed = _handleLiveBackOnce();
    _liveBackConsumed = consumed;
    return consumed;
  }

  bool _handleLiveBackOnce() {
    if (_popLivePopup()) return true;
    if (_rightOpen) {
      setState(() => _rightOpen = false);
      return true;
    }
    if (_leftOpen) {
      setState(() {
        _leftOpen = false;
        _epgOpen = false;
      });
      return true;
    }
    if (_channelInfoVisible || _chromeVisible || _catchupChrome) {
      setState(() {
        _chromeVisible = false;
        _catchupChrome = false;
        _channelInfoVisible = false;
      });
      _catchupHideTimer?.cancel();
      return true;
    }
    if (_catchup) {
      unawaited(_exitCatchup());
      return true;
    }
    if (_immersive) {
      unawaited(_exitImmersive());
      return true;
    }
    return false;
  }

  Future<void> _bootstrap({bool forceLoad = false}) async {
    final serial = _playSerial;
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
      _unlocked.clear();
    });
    // 停上一页与拉直播源并行：频道列表不堵在 prepareLeave / 整段播控配置上。
    final leaveFut = DetailScreen.prepareLeave();
    try {
      final settingsFut = ref.read(apiProvider).getSettings();
      final sourcesFut = ref.read(apiProvider).liveSources();
      Map<String, dynamic> settings = const {};
      try {
        final st = await settingsFut;
        if (!mounted) return;
        settings = KotvSettingsCache.settingsOf(st);
        KotvSettingsCache.replace(settings);
        _applyLiveBootstrapSettings(settings);
      } catch (_) {}
      if (!mounted) return;
      final data = await sourcesFut;
      if (!mounted) return;
      _sources = ((data['sources'] as List?) ?? []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
      if (_sources.isEmpty) {
        setState(() => _loading = false);
        await leaveFut;
        return;
      }
      final keepSrc = await _preferredSourceIndex();
      if (!mounted) return;
      // 先出列表；起播前再等 leave + 播控落到引擎。
      await _loadSource(keepSrc, autoPlay: false, force: forceLoad);
      if (!mounted) return;
      await leaveFut;
      if (!mounted) return;
      await _applyLiveBootstrapPlayback(settings);
      if (!mounted || serial != _playSerial) return;
      final restored = await _tryRestoreKeep();
      if (!mounted || serial != _playSerial) return;
      if (!restored) await _playFirstChannel();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
      try {
        await leaveFut;
      } catch (_) {}
    }
  }

  /// 只写 Dart 侧直播偏好，不碰引擎（列表可先显示）。
  void _applyLiveBootstrapSettings(Map<String, dynamic> settings) {
    final decode = '${settings['playerDecode'] ?? 'auto'}'.trim();
    if (decode.isNotEmpty) {
      _decodeMode = decode;
      _prefDecodeMode = decode;
    }
    _renderMode = kotvNormalizePlayerRender('${settings['playerRender'] ?? 'surface'}');
    _mpvOpts = KotvMpvOpts.fromSettings(settings, decodeMode: _decodeMode);
    var playerVal = '${settings['playerLive'] ?? ''}'.trim();
    if (playerVal.isEmpty) {
      playerVal = kotvDefaultLivePlayer();
    }
    _playerVal = kotvClampPlayerVal(playerVal, live: true);
    _prefPlayerVal = _playerVal;
    final failoverMode = '${settings['playerFailover'] ?? 'auto'}'.trim().toLowerCase();
    _prefPlayerFailover = (failoverMode == 'off' || failoverMode == 'false') ? 'off' : 'auto';
    _liveAutoChange = kotvSettingsFlag(settings['liveChange'] ?? settings['liveAutoChange'], def: true);
    _liveAcross = kotvSettingsMapFlag(settings, 'liveAcross', def: true);
    _liveInvert = kotvSettingsMapFlag(settings, 'liveInvert');
    final scaleLive = '${settings['playerScaleLive'] ?? settings['playerScale'] ?? 'default'}'.trim();
    _liveScale = scaleLive.isEmpty ? 'default' : scaleLive;
    _liveAspect = kotvAspectFromScale(_liveScale);
    _playerBackground = kotvPlayerBackgroundFromSettings(settings);
    kotvApplyPlayUaSetting('${settings['ua'] ?? ''}');
  }

  /// 列表已出后：把解码/渲染/字幕/音量落到当前引擎。
  Future<void> _applyLiveBootstrapPlayback(Map<String, dynamic> settings) async {
    if (settings.isEmpty) return;
    try {
      kotvPushPlayerSettings(
        settings,
        mpvOpts: _mpvOpts.copyWith(decodeMode: _decodeMode),
        current: _playback,
        mpv: _mk,
        exo: _exo,
        fvp: _fvp,
      );
      final vol = double.tryParse('${settings['playerVolume'] ?? ''}');
      if (vol != null && vol > 0) {
        await _playback.setVolume(vol.clamp(1, 100));
      } else if (vol != null && vol <= 0) {
        await _playback.setVolume(80);
        try {
          await _persistLiveSetting('playerVolume', '80');
        } catch (_) {}
      }
      if (!mounted) return;
      await _playback.setDecodeMode(_decodeMode);
      await _playback.setRenderMode(_renderMode);
      unawaited(_playback.setVideoScale(_liveScale));
      _syncAndroidAutoPip();
    } catch (_) {}
  }

  Future<String> _readLiveKeep() async {
    final cached = KotvSettingsCache.get('liveKeep').trim();
    if (cached.isNotEmpty) return cached;
    try {
      final map = await KotvSettingsCache.fetch(ref.read(apiProvider));
      return '${map['liveKeep'] ?? ''}'.trim();
    } catch (_) {
      return '';
    }
  }

  Future<int> _preferredSourceIndex() async {
    try {
      final keep = await _readLiveKeep();
      if (keep.isEmpty || _sources.isEmpty) return 0;
      final parts = keep.split(_liveKeepSep);
      if (parts.isEmpty) return 0;
      final srcName = parts[0];
      for (var i = 0; i < _sources.length; i++) {
        final n = '${_sources[i]['name'] ?? ''}';
        final u = '${_sources[i]['url'] ?? ''}';
        if (n == srcName) return i;
        if (srcName.isNotEmpty && (n.contains(srcName) || srcName.contains(n) || u.contains(srcName))) return i;
      }
    } catch (_) {}
    return 0;
  }

  Future<void> _loadFavNames() async {
    try {
      final data = await ref.read(apiProvider).library('liveKeep');
      final names = (data['names'] as List?)
              ?.map((e) => '$e'.trim())
              .where((e) => e.isNotEmpty)
              .toList() ??
          const <String>[];
      _favNames
        ..clear()
        ..addAll(names);
    } catch (_) {
      // 引擎未就绪时保持内存态
    }
  }

  Future<void> _persistFavNames() async {
    try {
      await ref.read(apiProvider).libraryAction({
        'action': 'replaceLiveFav',
        'names': _favNames.toList(),
      });
    } catch (_) {}
  }

  /// 源内无「收藏」组时，按持久化频道名注入第 0 组。
  /// 每条带上 `_srcGroup`/`_srcChannel`，开播/EPG 打引擎时用真实下标。
  void _applyFavoriteGroup() {
    _groups.removeWhere((g) => g['_kotvFav'] == true);
    final hasSourceFav = _groups.any((g) => '${g['name'] ?? ''}' == _liveFavGroupName);
    if (hasSourceFav || _favNames.isEmpty) return;
    final seen = <String>{};
    final favChs = <Map<String, dynamic>>[];
    for (var gi = 0; gi < _groups.length; gi++) {
      final chs = ((_groups[gi]['channels'] as List?) ?? []).whereType<Map>().toList();
      for (var ci = 0; ci < chs.length; ci++) {
        final c = chs[ci];
        final name = '${c['name'] ?? ''}'.trim();
        if (name.isEmpty || !_favNames.contains(name) || !seen.add(name)) continue;
        favChs.add({
          ...Map<String, dynamic>.from(c),
          '_srcGroup': gi,
          '_srcChannel': ci,
        });
      }
    }
    if (favChs.isEmpty) return;
    _groups.insert(0, {
      'name': _liveFavGroupName,
      'channels': favChs,
      '_kotvFav': true,
    });
  }

  /// 注入的收藏组占 UI 第 0 位时，其后分组的引擎下标要减 1。
  bool get _hasInjectedFavGroup =>
      _groups.isNotEmpty && _groups.first['_kotvFav'] == true;

  /// 界面分组下标 → 引擎分组下标。注入的收藏组没有引擎下标。
  int? _engineGroupIndex(int uiGroup) {
    if (uiGroup < 0 || uiGroup >= _groups.length) return null;
    if (_groups[uiGroup]['_kotvFav'] == true) return null;
    final eng = _hasInjectedFavGroup ? uiGroup - 1 : uiGroup;
    if (eng < 0) return null;
    return eng;
  }

  /// UI 分组/频道 → 引擎真实下标（收藏组映射回源内位置）。
  ({int group, int channel})? _engineChannelRef(int uiGroup, int uiChannel) {
    if (uiGroup < 0 || uiGroup >= _groups.length) return null;
    final g = _groups[uiGroup];
    final chs = ((g['channels'] as List?) ?? []).whereType<Map>().toList();
    if (uiChannel < 0 || uiChannel >= chs.length) return null;
    if (g['_kotvFav'] != true) {
      final engGroup = _engineGroupIndex(uiGroup);
      if (engGroup == null) return null;
      return (group: engGroup, channel: uiChannel);
    }
    final ch = chs[uiChannel];
    final sg = ch['_srcGroup'];
    final sc = ch['_srcChannel'];
    final gi = sg is int ? sg : int.tryParse('$sg');
    final ci = sc is int ? sc : int.tryParse('$sc');
    if (gi != null && ci != null && gi >= 0 && ci >= 0) {
      return (group: gi, channel: ci);
    }
    final name = '${ch['name'] ?? ''}'.trim();
    if (name.isEmpty) return null;
    for (var i = 0; i < _groups.length; i++) {
      if (_groups[i]['_kotvFav'] == true) continue;
      final list = ((_groups[i]['channels'] as List?) ?? []).whereType<Map>().toList();
      for (var j = 0; j < list.length; j++) {
        if ('${list[j]['name'] ?? ''}'.trim() == name) {
          final engGroup = _engineGroupIndex(i);
          if (engGroup == null) continue;
          return (group: engGroup, channel: j);
        }
      }
    }
    return null;
  }

  /// 引擎 Load 下发的 urls：非空可直开；空串占位表示须 livePlay（保留线路下标）。
  List<String> _channelPlayUrls(Map ch) {
    final raw = ch['urls'];
    if (raw is! List) return const [];
    return [for (final e in raw) '$e'.trim()];
  }

  /// 与 urls 平行的可直开 CDN（PreparePlayback 的 direct）。
  List<String> _channelDirectUrls(Map ch) {
    final raw = ch['directs'];
    if (raw is! List) return const [];
    return [for (final e in raw) '$e'.trim()];
  }

  void _writeBackLivePlayUrl(
    Map ch, {
    required int line,
    required String url,
    String direct = '',
    Map<String, String>? headers,
    String format = '',
    Map<String, dynamic>? drm,
    List<Map<String, dynamic>>? subs,
  }) {
    // 透传 id 会过期，写回会导致同台再开失败。
    if (kotvIsEphemeralPlayUrl(url) || kotvIsEphemeralPlayUrl(direct)) {
      return;
    }
    final raw = ch['urls'];
    final list = raw is List ? List<dynamic>.from(raw) : <dynamic>[];
    while (list.length <= line) {
      list.add('');
    }
    if (line >= 0 && line < list.length) {
      list[line] = url;
      ch['urls'] = list;
    }
    final dRaw = ch['directs'];
    final dList = dRaw is List ? List<dynamic>.from(dRaw) : <dynamic>[];
    while (dList.length <= line) {
      dList.add('');
    }
    if (line >= 0 && line < dList.length) {
      dList[line] = direct;
      ch['directs'] = dList;
    }
    if (headers != null && headers.isNotEmpty) {
      ch['headers'] = Map<String, String>.from(headers);
      final hl = ch['headerLines'];
      final hList = hl is List ? List<dynamic>.from(hl) : <dynamic>[];
      while (hList.length <= line) {
        hList.add(<String, String>{});
      }
      if (line >= 0 && line < hList.length) {
        hList[line] = Map<String, String>.from(headers);
        ch['headerLines'] = hList;
      }
    }
    if (format.isNotEmpty) ch['format'] = format;
    if (drm != null) ch['drm'] = drm;
    if (subs != null && subs.isNotEmpty) {
      ch['subs'] = List<Map<String, dynamic>>.from(subs);
    } else {
      ch.remove('subs');
    }
  }

  List<Map<String, dynamic>>? _channelSubs(Map ch) {
    final raw = ch['subs'];
    if (raw is! List || raw.isEmpty) return null;
    final out = <Map<String, dynamic>>[
      for (final s in raw)
        if (s is Map)
          {
            'url': '${s['url'] ?? ''}',
            'name': '${s['name'] ?? ''}',
            'lang': '${s['lang'] ?? ''}',
            'format': '${s['format'] ?? ''}',
          },
    ];
    return out.isEmpty ? null : out;
  }

  Map<String, String>? _channelHeaders(Map ch, {int? line}) {
    final lines = ch['headerLines'];
    if (line != null && lines is List && line >= 0 && line < lines.length) {
      final raw = lines[line];
      if (raw is Map) {
        final out = <String, String>{
          for (final e in raw.entries)
            if ('${e.key}'.trim().isNotEmpty && '${e.value}'.trim().isNotEmpty)
              '${e.key}': '${e.value}',
        };
        if (out.isNotEmpty) return out;
      }
    }
    final raw = ch['headers'];
    if (raw is! Map) return null;
    final out = <String, String>{
      for (final e in raw.entries)
        if ('${e.key}'.trim().isNotEmpty && '${e.value}'.trim().isNotEmpty)
          '${e.key}': '${e.value}',
    };
    return out.isEmpty ? null : out;
  }

  Future<void> _toggleChannelFav(int chIdx) async {
    final chs = _channels;
    if (chIdx < 0 || chIdx >= chs.length) return;
    final name = '${chs[chIdx]['name'] ?? ''}'.trim();
    if (name.isEmpty) return;
    final adding = !_favNames.contains(name);
    final groupNameBefore = _groupIdx < _groups.length ? '${_groups[_groupIdx]['name'] ?? ''}' : '';
    final playingName = _chIdx >= 0 && _chIdx < chs.length ? '${chs[_chIdx]['name'] ?? ''}' : '';
    if (adding) {
      _favNames.add(name);
    } else {
      _favNames.remove(name);
    }
    await _persistFavNames();
    _applyFavoriteGroup();
    _rebindPlaying();
    var gi = _groups.indexWhere((g) => '${g['name'] ?? ''}' == groupNameBefore);
    if (gi < 0) gi = 0;
    setState(() {
      _groupIdx = gi.clamp(0, _groups.isEmpty ? 0 : _groups.length - 1);
      final list = _channels;
      if (playingName.isNotEmpty) {
        final idx = list.indexWhere((c) => '${c['name'] ?? ''}' == playingName);
        _chIdx = idx >= 0 ? idx : (list.isEmpty ? -1 : list.length - 1);
      } else if (_chIdx >= list.length) {
        _chIdx = list.isEmpty ? -1 : list.length - 1;
      }
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(adding ? '已加入收藏' : '已移出收藏'), duration: const Duration(seconds: 2)),
    );
  }

  void _rememberLiveTimeout(Map<String, dynamic> data) {
    final n = int.tryParse('${data['timeout'] ?? ''}');
    _livePlayTimeoutSec = (n == null || n < 1) ? 15 : n;
  }

  List<Map<String, dynamic>> _parseLiveGroups(Map<String, dynamic> data) {
    return ((data['groups'] as List?) ?? []).whereType<Map>().map((e) {
      final g = Map<String, dynamic>.from(e);
      g['channels'] = ((g['channels'] as List?) ?? const [])
          .whereType<Map>()
          .map((c) => Map<String, dynamic>.from(c))
          .toList();
      return g;
    }).toList();
  }

  void _applyLoadedGroups(List<Map<String, dynamic>> groups, {required String title}) {
    _groups = groups;
    _groupIdx = 0;
    _chIdx = -1;
    _playGroupIdx = -1;
    _playChIdx = -1;
    _playGroupName = '';
    _playChName = '';
    _groupChannelPos.clear();
    _title = title;
  }

  Future<void> _loadSource(int index, {bool autoPlay = false, bool force = false}) async {
    if (!mounted) return;
    // 加载期间离开直播或已手动选台：不再自动起播。
    final serial = _playSerial;
    setState(() {
      _loading = true;
      _srcIdx = index;
      _status = force ? '刷新直播源…' : '加载直播源…';
      _unlocked.clear();
      _epgDays = [];
      _programs = [];
      _catchup = false;
      _catchupChrome = false;
      _catchupProgIdx = -1;
    });
    try {
      final data = await ref.read(apiProvider).liveLoad(index: index, force: force);
      if (!mounted) return;
      final groups = _parseLiveGroups(data);
      final title = '${data['name'] ?? '直播'}';
      _rememberLiveTimeout(data);
      await _loadFavNames();
      _applyLoadedGroups(groups, title: title);
      _applyFavoriteGroup();
      setState(() {
        _loading = false;
        _status = _liveIdleStatus;
      });
      if (autoPlay && serial == _playSerial) {
        final restored = await _tryRestoreKeep();
        if (!mounted) return;
        if (!restored) await _playFirstChannel();
      }
    } catch (e) {
      if (!mounted) return;
      if (kotvMessageNeedsLogin(e)) {
        setState(() {
          _loading = false;
          _status = _liveIdleStatus;
        });
        final ok = await kotvPresentLoginIfNeeded(context, ref);
        if (ok && mounted) {
          await _loadSource(index, autoPlay: autoPlay, force: force);
        }
        return;
      }
      setState(() {
        _loading = false;
        _status = '加载失败: $e';
      });
    }
  }

  Future<bool> _tryRestoreKeep() async {
    try {
      final keep = await _readLiveKeep();
      if (keep.isEmpty) return false;
      final parts = keep.split(_liveKeepSep);
      if (parts.length < 3) return false;
      final groupName = parts[1];
      final chName = parts[2];
      final lineURL = parts.length >= 4 ? parts[3] : '';
      for (var gi = 0; gi < _groups.length; gi++) {
        if (_groupLocked(gi)) continue;
        final gName = '${_groups[gi]['name'] ?? ''}';
        if (groupName.isNotEmpty && gName != groupName) continue;
        final chs = ((_groups[gi]['channels'] as List?) ?? []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
        for (var ci = 0; ci < chs.length; ci++) {
          if ('${chs[ci]['name'] ?? ''}' != chName) continue;
          var line = (chs[ci]['line'] as int?) ?? 0;
          if (lineURL.isNotEmpty) {
            final asIdx = int.tryParse(lineURL);
            if (asIdx != null && asIdx >= 0) {
              line = asIdx;
            }
          }
          setState(() {
            _groupIdx = gi;
            _chIdx = ci;
          });
          await _playChannel(ci, line: line);
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  Future<void> _playFirstChannel() async {
    var start = 0;
    if (_groups.length > 1 && '${_groups[0]['name'] ?? ''}' == _liveFavGroupName) start = 1;
    for (var n = 0; n < _groups.length; n++) {
      final gi = (start + n) % _groups.length;
      if (_groupLocked(gi)) continue;
      final chs = ((_groups[gi]['channels'] as List?) ?? []).whereType<Map>().toList();
      if (chs.isEmpty) continue;
      setState(() => _groupIdx = gi);
      await _playChannel(0);
      return;
    }
  }

  Future<void> _saveLiveKeep() async {
    if (_chIdx < 0 || _groups.isEmpty) return;
    final g = _groups[_groupIdx.clamp(0, _groups.length - 1)];
    final chs = _channels;
    if (_chIdx >= chs.length) return;
    final ch = chs[_chIdx];
    final srcName = '${_sources.isEmpty ? '' : (_sources[_srcIdx]['name'] ?? _sources[_srcIdx]['url'] ?? '')}';
    final groupName = '${g['name'] ?? '未分组'}';
    final chName = '${ch['name'] ?? ''}';
    // 线路记序号，避免代理 URL 变化导致无法匹配
    final lineURL = '$_line';
    final val = [srcName, groupName, chName, lineURL].join(_liveKeepSep);
    try {
      await _persistLiveSetting('liveKeep', val);
    } catch (_) {}
  }

  List<Map<String, dynamic>> get _channels {
    if (_groups.isEmpty) return const [];
    final g = _groups[_groupIdx.clamp(0, _groups.length - 1)];
    final chs = g['channels'];
    return chs is List<Map<String, dynamic>> ? chs : const [];
  }

  bool _groupLocked(int i) {
    if (i < 0 || i >= _groups.length) return false;
    final locked = _groups[i]['locked'] == true;
    return locked && !_unlocked.contains(i);
  }

  Future<bool> _ensureUnlocked(int groupIdx) async {
    if (!_groupLocked(groupIdx)) return true;
    final ctrl = TextEditingController();
    final pal = KotvPalette.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: pal.dialogBg,
        title: Text('解锁分组', style: TextStyle(color: pal.fg)),
        content: KotvTvTextField(
          controller: ctrl,
          autofocus: true,
          obscureText: true,
          style: TextStyle(color: pal.fg),
          decoration: InputDecoration(
            hintText: '请输入分组密码',
            hintStyle: TextStyle(color: pal.muted),
          ),
        ),
        actions: [
          KotvFocusAction(label: '取消', color: pal.muted, onPressed: () => Navigator.pop(ctx, false)),
          KotvFocusAction(label: '确定', color: pal.fg, onPressed: () => Navigator.pop(ctx, true)),
        ],
      ),
    );
    if (ok != true) {
      ctrl.dispose();
      return false;
    }
    try {
      final eng = _engineGroupIndex(groupIdx);
      if (eng == null) {
        ctrl.dispose();
        return false;
      }
      await ref.read(apiProvider).liveUnlock(group: eng, password: ctrl.text.trim());
      setState(() => _unlocked.add(groupIdx));
      ctrl.dispose();
      return true;
    } catch (e) {
      ctrl.dispose();
      if (!mounted) return false;
      if (kotvMessageNeedsLogin(e)) {
        await kotvPresentLoginIfNeeded(context, ref);
        return false;
      }
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      return false;
    }
  }

  void _rememberPlaying(int groupIdx, int chIdx, String groupName, String chName) {
    _playGroupIdx = groupIdx;
    _playChIdx = chIdx;
    _playGroupName = groupName;
    _playChName = chName;
  }

  String _groupNameAt(int groupIdx) {
    if (groupIdx < 0 || groupIdx >= _groups.length) return '';
    return '${_groups[groupIdx]['name'] ?? ''}';
  }

  int _channelCountAt(int groupIdx) {
    if (groupIdx < 0 || groupIdx >= _groups.length) return 0;
    final raw = _groups[groupIdx]['channels'];
    return raw is List ? raw.length : 0;
  }

  /// 在该组选台后记下频道名。收藏列表重排后仍能找回这一台。
  void _rememberGroupChannel(int groupIdx, int chIdx) {
    final gname = _groupNameAt(groupIdx);
    if (gname.isEmpty || chIdx < 0 || chIdx >= _channelCountAt(groupIdx)) return;
    final raw = _groups[groupIdx]['channels'];
    if (raw is! List || chIdx >= raw.length) return;
    final c = raw[chIdx];
    if (c is! Map) return;
    final cname = '${c['name'] ?? ''}'.trim();
    if (cname.isEmpty) return;
    _groupChannelPos[gname] = cname;
  }

  /// 该组上次选中的频道在当前列表中的下标。没选过或已经不在列表里时返回 -1。
  int _rememberedChannel(int groupIdx) {
    final gname = _groupNameAt(groupIdx);
    if (gname.isEmpty) return -1;
    final cname = _groupChannelPos[gname];
    if (cname == null || cname.isEmpty) return -1;
    final raw = _groups[groupIdx]['channels'];
    if (raw is! List) return -1;
    for (var i = 0; i < raw.length; i++) {
      final c = raw[i];
      if (c is Map && '${c['name'] ?? ''}'.trim() == cname) return i;
    }
    return -1;
  }

  /// 频道列表要滚到的下标。正在播的组用 [_chIdx]，其它组用记住的频道，没记过则由调用处滚到开头。
  int _channelListIndex() {
    if (_chIdx >= 0) return _chIdx;
    return _rememberedChannel(_groupIdx);
  }

  /// 收藏组插入或移除后，按名字把正在播的下标拨回去。
  void _rebindPlaying() {
    if (_playGroupName.isEmpty) return;
    for (var gi = 0; gi < _groups.length; gi++) {
      if ('${_groups[gi]['name'] ?? ''}' != _playGroupName) continue;
      final raw = _groups[gi]['channels'];
      if (raw is! List) continue;
      for (var ci = 0; ci < raw.length; ci++) {
        final c = raw[ci];
        if (c is! Map) continue;
        if ('${c['name'] ?? ''}' != _playChName) continue;
        _playGroupIdx = gi;
        _playChIdx = ci;
        return;
      }
    }
  }

  /// [allowUnlock]：点按可为锁定组弹解锁；焦点停留切换时勿弹窗。
  Future<void> _selectGroup(int i, {bool allowUnlock = true}) async {
    if (allowUnlock) {
      if (!await _ensureUnlocked(i)) return;
    } else if (_groupLocked(i)) {
      return;
    }
    final remembered = _rememberedChannel(i);
    final playingHere = i == _playGroupIdx && _playChIdx >= 0 && _playChIdx < _channelCountAt(i);
    setState(() {
      _groupIdx = i;
      // 只有正在播的组才把 [_chIdx] 填上。信息条继续用正在播的那一台。
      _chIdx = playingHere ? _playChIdx : -1;
    });
    _showAt(_groupScroll, _groupIdx, _groupStride);
    // 正在播的组滚到正在播的频道。其它组滚到上次选中的频道；没选过则停在开头。
    final scrollTo = playingHere ? _playChIdx : (remembered < 0 ? 0 : remembered);
    _showAt(_channelScroll, scrollTo, _channelStride);
    if (_chIdx >= 0) unawaited(_loadEpg());
  }

  Future<void> _loadEpg() async {
    final uiGroup = _groupIdx;
    final uiChannel = _chIdx;
    if (uiChannel < 0 || uiGroup < 0) return;
    final eng = _engineChannelRef(uiGroup, uiChannel);
    if (eng == null) return;
    final serial = ++_epgSerial;
    try {
      final data = await ref.read(apiProvider).liveEpg(group: eng.group, channel: eng.channel);
      final days = ((data['days'] as List?) ?? []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
      var dayIdx = 0;
      final today = _localDateString();
      for (var i = 0; i < days.length; i++) {
        if ('${days[i]['date']}' == today) {
          dayIdx = i;
          break;
        }
      }
      final progs = days.isEmpty
          ? <Map<String, dynamic>>[]
          : (((days[dayIdx]['list'] as List?) ?? []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList());
      final logo = '${data['logo'] ?? ''}'.trim();
      if (!mounted || serial != _epgSerial) return;
      final stillHere = _groupIdx == uiGroup && _chIdx == uiChannel;
      final playingThis = _playGroupIdx == uiGroup && _playChIdx == uiChannel;
      if (!stillHere && !playingThis) return;
      setState(() {
        _epgDays = days;
        _dayIdx = dayIdx;
        _programs = progs;
        _fillChannelLogo(uiGroup, uiChannel, logo);
      });
      _scheduleScrollEpgToHighlight();
    } catch (_) {
      if (!mounted || serial != _epgSerial) return;
      if (_groupIdx == uiGroup && _chIdx == uiChannel) {
        setState(() {
          _epgDays = [];
          _programs = [];
        });
      }
    }
  }

  /// XMLTV <icon> 只补进发起请求的那一台。列表里原先已有 logo 时不覆盖。
  void _fillChannelLogo(int group, int channel, String logo) {
    if (logo.isEmpty || group < 0 || group >= _groups.length || channel < 0) return;
    final raw = _groups[group]['channels'];
    if (raw is! List || channel >= raw.length) return;
    final c = raw[channel];
    if (c is! Map) return;
    if ('${c['logo'] ?? ''}'.trim().isNotEmpty) return;
    raw[channel] = Map<String, dynamic>.from(c)..['logo'] = logo;
  }

  Map<String, dynamic>? get _playingChannel {
    if (_playGroupIdx < 0 || _playChIdx < 0 || _playGroupIdx >= _groups.length) return null;
    final raw = _groups[_playGroupIdx]['channels'];
    if (raw is! List || _playChIdx >= raw.length) return null;
    final c = raw[_playChIdx];
    if (c is Map<String, dynamic>) return c;
    if (c is Map) return Map<String, dynamic>.from(c);
    return null;
  }

  /// 回看项优先，否则「正在播出」；供 EPG 列表滚到可视区。
  int _epgHighlightIndex() {
    if (_catchup && _catchupProgIdx >= 0 && _catchupProgIdx < _programs.length) {
      return _catchupProgIdx;
    }
    for (var i = 0; i < _programs.length; i++) {
      if (_programs[i]['now'] == true) return i;
    }
    return -1;
  }

  void _scheduleScrollEpgToHighlight() {
    _showAt(_epgScroll, _epgHighlightIndex(), _epgStride);
  }

  /// 分类、频道、节目单直接停在当前项，不从列表开头滑过去。
  void _scheduleScrollToCurrent({bool epg = true}) {
    _showAt(_groupScroll, _groupIdx, _groupStride);
    _showAt(_channelScroll, _chIdx, _channelStride);
    if (epg) _scheduleScrollEpgToHighlight();
  }

  /// 当前项已经在视口里就不动。不在视口里时再跳到它的起点。
  /// 列表高度还是 0 时先记下偏移，布局完成后再跳，避免被夹到 0 后停在第一项。
  void _showAt(KotvJumpController controller, int index, double stride, [int attempt = 0]) {
    if (index < 0 || stride <= 0) return;
    final start = index * stride;
    final end = start + stride;
    if (!controller.hasClients || !controller.position.hasContentDimensions) {
      controller.arm(start);
      return;
    }
    final pos = controller.position;
    if (pos.maxScrollExtent <= 0 && start > 0 && attempt < 6) {
      controller.arm(start);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showAt(controller, index, stride, attempt + 1);
      });
      return;
    }
    final viewStart = pos.pixels;
    final viewEnd = viewStart + pos.viewportDimension;
    if (end > viewStart && start < viewEnd) return;
    // 拖动或惯性滑动时跳转会掐断手势，列表就一顿一顿的。
    if (pos.isScrollingNotifier.value) return;
    final target = start.clamp(pos.minScrollExtent, pos.maxScrollExtent);
    if ((pos.pixels - target).abs() < 0.5) return;
    pos.jumpTo(target);
  }

  /// 行高或当前下标变了，等这一帧布局完再判断要不要露出当前项。
  void _pinList(KotvJumpController controller, int index, double stride, double previous, int pinned) {
    if (controller.hasClients && (stride - previous).abs() <= 0.5 && index == pinned) return;
    if (!controller.hasClients) {
      _showAt(controller, index, stride);
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showAt(controller, index, stride);
    });
  }

  double _oneLine(BuildContext context, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: '国', style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final h = painter.height;
    painter.dispose();
    return h;
  }

  Future<void> _openLiveUrl(
    String url, {
    required int serial,
    String directUrl = '',
    Map<String, String>? headers,
    Map<String, dynamic>? drm,
    bool live = true,
    String? format,
    Duration startAt = Duration.zero,
    List<Map<String, dynamic>>? externalSubs,
    /// 超时/无画面恢复：沿用当前会话引擎，勿改写用户偏好。
    String? startPlayerOverride,
    /// 超时/无画面恢复：沿用当前会话解码（常为 soft），勿改写 [_prefDecodeMode]。
    String? startDecodeOverride,
  }) async {
    if (!await _primeDesktopMpv()) return;
    if (!mounted || serial != _playSerial) return;
    // 热缓存同步 peek，避免每台换台多一次 async。
    var playSettings = KotvSettingsCache.peek();
    if (playSettings.isEmpty) {
      try {
        playSettings = await KotvSettingsCache.fetch(ref.read(apiProvider));
      } catch (_) {}
    }
    if (playSettings.isNotEmpty) {
      final fo = '${playSettings['playerFailover'] ?? ''}'.trim();
      if (fo.isNotEmpty) {
        _prefPlayerFailover = KotvPlaybackFailover.enabledFromSetting(fo) ? 'auto' : 'off';
      }
      _renderMode = kotvNormalizePlayerRender('${playSettings['playerRender'] ?? _renderMode}');
      // across/invert/change 仅在 bootstrap / 面板切换时更新，避免每次开播覆盖用户刚改的开关。
      final scaleLive = '${playSettings['playerScaleLive'] ?? playSettings['playerScale'] ?? 'default'}'.trim();
      _liveScale = scaleLive.isEmpty ? 'default' : scaleLive;
      _liveAspect = kotvAspectFromScale(_liveScale);
      _exo?.applyPlayerOptions(playSettings);
      _fvp?.applyPlayerOptions(playSettings);
    }
    final renderMode = kotvNormalizePlayerRender(_renderMode);
    final hasDrm = drm != null && '${drm['type'] ?? ''}'.trim().isNotEmpty;
    final startPlayer = (hasDrm && kotvIsAndroid())
        ? 'innie#exo'
        : (startPlayerOverride ?? _prefPlayerVal);
    if (kotvIsExternalPlayer(startPlayer)) {
      if (!mounted || serial != _playSerial) return;
      await _playback.pause();
      if (!mounted || serial != _playSerial) return;
      setState(() {
        _playUrl = url;
        _playDirect = directUrl;
        _playHeaders = headers;
        _playerVal = startPlayer;
        _prefPlayerVal = startPlayer;
      });
      try {
        final result = await kotvLaunchExternalPlayer(
          player: startPlayer,
          url: url,
          headers: headers,
          title: _title,
          vod: false,
          context: context,
        );
        if (mounted && serial == _playSerial && !result.opened) {
          setState(() => _status = '未打开外部播放器');
        }
      } catch (e) {
        if (mounted && serial == _playSerial) setState(() => _status = '$e');
      }
      return;
    }
    final failover = KotvPlaybackFailover(
      playerVal: startPlayer,
      decodeMode: startDecodeOverride ?? _prefDecodeMode,
      settingsDecodeMode: _prefDecodeMode,
      lockExoForDrm: hasDrm && kotvIsAndroid(),
      enabled: KotvPlaybackFailover.enabledFromSetting(_prefPlayerFailover) && !hasDrm,
    );
    bool stale() => !mounted || serial != _playSerial;
    Object? lastError;
    for (var attempt = 0; attempt < 8; attempt++) {
      if (stale()) return;
      failover.markAttempt();
      final nextVal = failover.playerVal;
      final nextDecode = failover.decodeMode;
      final prevPlayer = _playerVal;
      final prevDecode = _decodeMode;
      final prevRender = _renderMode;
      final sameBackend = nextVal == prevPlayer && _playUrl.isNotEmpty;
      // 同后端换台：无闲置后端要停，跳过全表扫描。
      if (!sameBackend) {
        await _stopInactiveBackends(kotvEmbedBackend(nextVal));
        if (stale()) return;
      }
      final decodeChanged = nextDecode != prevDecode;
      final renderChanged = renderMode != prevRender;
      _playerVal = nextVal;
      _decodeMode = nextDecode;
      _renderMode = renderMode;
      final resolved = kotvResolvePreferredPlayOpen(
        playerVal: failover.playerVal,
        playUrl: url,
        directUrl: directUrl,
        rawHeaders: headers ?? const {},
        magnet: false,
        format: format,
        adFilterOn: kotvSettingsMapFlag(playSettings, 'adFilter', def: true),
      );
      final openUrl = resolved.url;
      final openHeaders = resolved.headers;
      _releasedHard = false;
      // 仅换后端才等一帧挂宿主；同后端换 URL 不必 endOfFrame。
      final needRemount = !sameBackend;
      setState(() {
        // 记住引擎 url/direct，换播放器时按能力重新分流。
        _playUrl = url;
        _playDirect = directUrl;
        _playHeaders = headers;
        _playDrm = hasDrm ? drm : null;
        _playerVal = nextVal;
        _decodeMode = nextDecode;
      });
      if (needRemount) {
        await WidgetsBinding.instance.endOfFrame;
        if (stale()) return;
      }
      _syncAndroidAutoPip();
      final pb = _playback;
      if (pb is ExoPlayback) {
        if (playSettings.isNotEmpty) {
          pb.applyPlayerOptions(playSettings);
        } else {
          pb.applyPlayerOptions({'playerRender': renderMode});
        }
      }
      if (decodeChanged || !sameBackend) {
        await pb.setDecodeMode(failover.decodeMode);
      }
      if (renderChanged || !sameBackend) {
        await pb.setRenderMode(renderMode);
      }
      if (stale()) return;
      try {
        // 外挂字幕须在 open 前写入，才能进 MediaItem。
        if (pb is ExoPlayback) {
          pb.setExternalSubs(externalSubs ?? const []);
        }
        // waitReady:false：媒体交给引擎即返回；出画守卫后台跑，换台不等 silent-guard。
        await pb.open(
          openUrl,
          headers: openHeaders,
          drm: hasDrm ? drm : null,
          live: live,
          format: format,
          startAt: startAt,
          waitReady: false,
        );
        if (stale()) {
          await kotvStopIfUnowned(pb, [_mk, _fvp, _exo, _html, _art, _xg, _zw]);
          return;
        }
        unawaited(pb.setVideoScale(_liveScale));
        if (_backend != KotvEmbedBackend.mpv && !pb.playing) {
          try {
            unawaited(pb.play());
          } catch (_) {}
        }
        _wireLivePlaybackErrors(pb);
        _wireLivePlaybackEnded(pb);
        unawaited(_bgEnsureLiveReady(
          pb: pb,
          failover: failover,
          serial: serial,
          url: url,
          directUrl: directUrl,
          headers: headers,
          drm: hasDrm ? drm : null,
          format: format,
          live: live,
          startAt: startAt,
          externalSubs: externalSubs,
        ));
        return;
      } on KotvSilentVideoException catch (e) {
        lastError = e;
        final retry = await _recoverAfterSilentVideo(
          pb: pb,
          failover: failover,
          serial: serial,
        );
        if (retry == null) return;
        if (retry) continue;
        break;
      } catch (e) {
        lastError = e;
        if (!failover.enabled) rethrow;
        // 其它开播错误：与无画面同一套换引擎 / 桌面 MPV 再建。
        final retry = await _recoverAfterSilentVideo(
          pb: pb,
          failover: failover,
          serial: serial,
        );
        if (retry == null) return;
        if (retry) continue;
        break;
      }
    }
    if (lastError != null) throw lastError;
    throw const KotvSilentVideoException();
  }

  /// 换台后后台出画守卫；失败且允许 failover 时再走 [_openLiveUrl]。
  Future<void> _bgEnsureLiveReady({
    required KotvPlayback pb,
    required KotvPlaybackFailover failover,
    required int serial,
    required String url,
    String directUrl = '',
    Map<String, String>? headers,
    Map<String, dynamic>? drm,
    String? format,
    required bool live,
    required Duration startAt,
    List<Map<String, dynamic>>? externalSubs,
  }) async {
    bool stale() => !mounted || serial != _playSerial;
    try {
      await pb.awaitReadyAfterOpen().timeout(Duration(seconds: _livePlayTimeoutSec));
    } on TimeoutException {
      if (stale() || _liveHasPicture(pb)) return;
      // 起播超时：先走 failover（非 soft→soft→换引擎），勿直接放弃。
      final retry = await _recoverAfterSilentVideo(
        pb: pb,
        failover: failover,
        serial: serial,
      );
      if (retry == null) {
        await _onLiveNotReady(serial);
        return;
      }
      if (retry) {
        // 记住本台可用引擎；解码用 override 传入，勿污染用户偏好。
        _prefPlayerVal = _playerVal;
        try {
          await _openLiveUrl(
            url,
            serial: serial,
            directUrl: directUrl,
            headers: headers,
            drm: drm,
            format: format,
            live: live,
            startAt: startAt,
            externalSubs: externalSubs,
            startPlayerOverride: _playerVal,
            startDecodeOverride: _decodeMode,
          );
        } catch (_) {}
        return;
      }
      await _onLiveNotReady(serial);
    } on KotvSilentVideoException {
      if (stale()) return;
      // 直播不预登记 HLS；失败只走播放器 failover（点播才切已有透传 url）。
      final retry = await _recoverAfterSilentVideo(
        pb: pb,
        failover: failover,
        serial: serial,
      );
      if (retry == null) {
        await _onLiveNotReady(serial);
        return;
      }
      if (retry) {
        // applyStep 已写入 _playerVal；retrySameEngine 同引擎再建。
        _prefPlayerVal = _playerVal;
        try {
          await _openLiveUrl(
            url,
            serial: serial,
            directUrl: directUrl,
            headers: headers,
            drm: drm,
            format: format,
            live: live,
            startAt: startAt,
            externalSubs: externalSubs,
            startPlayerOverride: _playerVal,
            startDecodeOverride: _decodeMode,
          );
        } catch (_) {}
        return;
      }
      await _onLiveNotReady(serial);
    } catch (_) {}
  }

  bool _liveHasPicture(KotvPlayback pb) =>
      (pb.width > 0 && pb.height > 0) || pb.isAudioOnlyContent;

  /// 限时内没有出画：换线开着且还有下一条就切，否则标播放超时。
  Future<void> _onLiveNotReady(int serial) async {
    if (!mounted || serial != _playSerial) return;
    if (_liveAutoChange && _lines > 1 && _line >= 0 && _line < _lines - 1) {
      await _tryFailSwitchOnPlaybackError();
      return;
    }
    if (mounted && serial == _playSerial) {
      setState(() => _status = '播放超时');
    }
  }

  void _unwireLivePlaybackErrors() {
    final pb = _errorWiredPb;
    final cb = _playbackErrorListener;
    if (pb != null && cb != null) {
      try {
        pb.removeListener(cb);
      } catch (_) {}
    }
    _errorWiredPb = null;
    _playbackErrorListener = null;
  }

  void _wireLivePlaybackErrors(KotvPlayback pb) {
    _unwireLivePlaybackErrors();
    _playbackErrorListener = () {
      if (!mounted || _playUrl.isEmpty) return;
      final err = pb.lastError;
      if (err == null || err.trim().isEmpty) return;
      unawaited(_tryFailSwitchOnPlaybackError());
    };
    _errorWiredPb = pb;
    pb.addListener(_playbackErrorListener!);
  }

  void _unwireLivePlaybackEnded() {
    _endedSub?.cancel();
    _endedSub = null;
  }

  void _wireLivePlaybackEnded(KotvPlayback pb) {
    _unwireLivePlaybackEnded();
    _endedSub = pb.completedStream.listen((done) {
      if (!done || !mounted || _playUrl.isEmpty) return;
      unawaited(_onLivePlaybackEnded());
    });
  }

  /// 播完：回看尽量下一可回看节目；否则下一台（跳过收藏/空/锁）。
  Future<void> _onLivePlaybackEnded() async {
    if (_endedBusy) return;
    _endedBusy = true;
    try {
      if (_catchup) {
        for (var i = _catchupProgIdx + 1; i < _programs.length; i++) {
          if (_programs[i]['catchup'] == true) {
            await _playCatchup(i);
            return;
          }
        }
      }
      await _stepChannel(delta: _liveInvert ? -1 : 1);
    } finally {
      _endedBusy = false;
    }
  }

  /// 播放中出错：失败换线开且非末线时切下一线（与开播 catch 同策略）。
  Future<void> _tryFailSwitchOnPlaybackError() async {
    if (!_liveAutoChange || _failSwitchBusy) return;
    if (_chIdx < 0 || _lines <= 1 || _line >= _lines - 1) return;
    _failSwitchBusy = true;
    final serial = _playSerial;
    final chIdx = _chIdx;
    final next = _line + 1;
    try {
      if (mounted) {
        setState(() => _status = '线路失败，自动换线 ${next + 1}/$_lines…');
      }
      await _playChannel(chIdx, line: next);
    } finally {
      if (serial == _playSerial || mounted) _failSwitchBusy = false;
    }
  }

  /// 全屏/竖屏/横屏共用画面。原生 MPV 画面层用 GlobalKey 保活。
  Widget _buildSharedLiveVideo() {
    final inner = _liveVideoInner();
    if (kotvUsesNativeMpv() && _mk is NativeMpvPlayback) {
      return KeyedSubtree(key: _videoHostKey, child: inner);
    }
    return inner;
  }

  Widget _liveVideoInner() {
    if (_playUrl.isEmpty) {
      return const ColoredBox(color: Colors.black);
    }
    // 勿包 ListenableBuilder：position/playing 高频 notify 会重建 Texture，PC FVP 可掉到 ~5fps。
    Widget view = kotvPlaybackView(
      playerVal: _playerVal,
      playback: _playback,
      mpv: _mk,
      fit: _liveAspect.fit,
    );
    final ratio = _liveAspect.ratio;
    final mpvNativeScale = kotvUsesNativeMpv() && _mk is NativeMpvPlayback;
    if (!mpvNativeScale && ratio != null && ratio > 0) {
      view = ColoredBox(
        color: Colors.black,
        child: Center(child: AspectRatio(aspectRatio: ratio, child: view)),
      );
    }
    return ExcludeFocus(
      child: Stack(
        fit: StackFit.expand,
        children: [
          view,
          kotvAudioStageOverlay(
            playback: _playback,
            coverUrl: _currentLogo,
          ),
        ],
      ),
    );
  }

  /// 仅 Android Hybrid：解析/无帧/起播缓冲盖住防叠影。
  /// 勿用 stalling：中途补缓存会盖黑最后一帧。换台不盖，保留上一台帧。
  Widget _buildLiveSurfaceCover() {
    if (kotvIsDesktop()) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: _playback,
      builder: (context, _) {
        final loading = _loading ||
            _status.contains('解析') ||
            _status.contains('加载') ||
            _status.contains('嗅探');
        // 纯音频无尺寸是正常态，勿盖黑挡掉音频叠层。
        final noFrame = kotvNeedsBlankSurfaceCover(_playback);
        final startBuf = !_playback.playing && _playback.buffering;
        // 换台中若仍有上一帧尺寸，不盖黑。
        final cover = loading ||
            (noFrame && !_status.contains('换台')) ||
            (startBuf && !_status.contains('换台'));
        if (!cover) return const SizedBox.shrink();
        return const IgnorePointer(child: ColoredBox(color: Colors.black));
      },
    );
  }

  String _liveScaleLabel(String key) {
    return switch (key) {
      'fill' => '拉伸',
      'zoom' => 'Zoom',
      '16:9' => '16:9',
      '4:3' => '4:3',
      _ => '适应',
    };
  }

  Future<void> _persistLiveSetting(String key, String value) async {
    await KotvSettingsCache.set(ref.read(apiProvider), key, value);
  }

  Future<void> _cycleLiveScale() async {
    const keys = ['default', 'fill', 'zoom', '16:9', '4:3'];
    final i = keys.indexOf(_liveScale);
    final next = keys[(i < 0 ? 0 : i + 1) % keys.length];
    setState(() {
      _liveScale = next;
      _liveAspect = kotvAspectFromScale(next);
    });
    unawaited(_playback.setVideoScale(next));
    try {
      await _persistLiveSetting('playerScaleLive', next);
    } catch (_) {}
  }

  Future<void> _toggleLiveFlag(String key, bool next) async {
    setState(() {
      if (key == 'liveAcross') _liveAcross = next;
      if (key == 'liveInvert') _liveInvert = next;
      if (key == 'liveChange') _liveAutoChange = next;
    });
    try {
      await _persistLiveSetting(key, next ? 'true' : 'false');
    } catch (_) {}
  }

  void _onLiveAcross() => unawaited(_toggleLiveFlag('liveAcross', !_liveAcross));
  void _onLiveInvert() => unawaited(_toggleLiveFlag('liveInvert', !_liveInvert));
  void _onLiveFailSwitch() => unawaited(_toggleLiveFlag('liveChange', !_liveAutoChange));

  /// 上下换台；[_liveAcross] 为真时到组边界跨组，[_liveInvert] 由调用方决定方向。
  /// 跨组时跳过「收藏」、空组与仍锁定的组。
  Future<void> _stepChannel({required int delta}) async {
    if (_groups.isEmpty) return;
    final chs = _channels;
    if (chs.isEmpty) {
      if (!_liveAcross || _groups.length < 2) return;
      final gNext = _nextPlayableGroup(_groupIdx, delta);
      if (gNext < 0) return;
      setState(() => _groupIdx = gNext);
      final n = _channels;
      if (n.isEmpty) return;
      await _playChannel(delta > 0 ? 0 : n.length - 1);
      return;
    }
    final next = _chIdx + delta;
    if (next >= 0 && next < chs.length) {
      await _playChannel(next);
      return;
    }
    if (!_liveAcross || _groups.length < 2) {
      await _playChannel(((next % chs.length) + chs.length) % chs.length);
      return;
    }
    final gNext = _nextPlayableGroup(_groupIdx, delta);
    if (gNext < 0) return;
    setState(() => _groupIdx = gNext);
    final n = _channels;
    if (n.isEmpty) return;
    await _playChannel(delta > 0 ? 0 : n.length - 1);
  }

  /// 从 [from] 起按 [delta] 找下一个可播分组（跳过收藏/空/锁定）。
  int _nextPlayableGroup(int from, int delta) {
    if (_groups.isEmpty) return -1;
    final step = delta >= 0 ? 1 : -1;
    for (var n = 1; n <= _groups.length; n++) {
      final gi = (from + step * n + _groups.length * n) % _groups.length;
      if (_groupShouldSkip(gi)) continue;
      final chs = ((_groups[gi]['channels'] as List?) ?? []).whereType<Map>().toList();
      if (chs.isEmpty) continue;
      return gi;
    }
    return -1;
  }

  bool _groupShouldSkip(int gi) {
    if (gi < 0 || gi >= _groups.length) return true;
    final g = _groups[gi];
    if (g['_kotvFav'] == true) return true;
    if ('${g['name'] ?? ''}' == _liveFavGroupName) return true;
    if (_groupLocked(gi)) return true;
    return false;
  }

  Future<void> _playChannel(int chIdx, {int? line, bool showList = false}) async {
    if (!await _ensureUnlocked(_groupIdx)) return;
    final chs = _channels;
    if (chIdx < 0 || chIdx >= chs.length) return;
    final serial = ++_playSerial;
    final ch = chs[chIdx];
    final playUrls = _channelPlayUrls(ch);
    final useLine = (line ?? (ch['line'] as int? ?? 0)).clamp(0, playUrls.isEmpty ? 0 : playUrls.length - 1);
    final playGroup = _groupIdx;
    final playGroupName = playGroup >= 0 && playGroup < _groups.length ? '${_groups[playGroup]['name'] ?? ''}' : '';
    final playChName = '${ch['name'] ?? ''}';
    final eng = _engineChannelRef(playGroup, chIdx);
    _rememberGroupChannel(playGroup, chIdx);
    setState(() {
      _chIdx = chIdx;
      _line = useLine;
      // 不写「换台」到 status：避免 BufferingOverlay force 盖住上一帧。
      _status = _liveIdleStatus;
      _title = '${ch['name'] ?? ''}';
      // showList=true 仅用于主动展开列表；默认选台后收起，避免挡画面。
      _leftOpen = showList;
      _epgOpen = false;
      _catchup = false;
      _catchupChrome = false;
      _catchupProgIdx = -1;
    });
    // 节目单在 _loadEpg 拿到新数据后再滚。
    _scheduleScrollToCurrent(epg: false);
    // EPG 与开播解耦：勿等 open 成功（FVP/MPV 卡住时节目单也出不来）。
    unawaited(_loadEpg());

    // 只停当前后端；与取地址并行。
    final stopFut = () async {
      try {
        await _stopPlaybackForLiveZap();
      } catch (_) {}
    }();

    try {
      late final String url;
      late final Map<String, String>? headers;
      late final Map<String, dynamic>? drm;
      late final String format;
      late final int lines;
      late final int lineIdx;
      late final String lineName;
      List<Map<String, dynamic>>? externalSubs;
      var sourceTitle = '';

      // 引擎：非空 urls[line] 可直开；空串须 livePlay。
      late final String direct;
      final engineBase = ref.read(apiProvider).baseUrl;
      final memUrl = playUrls.isEmpty ? '' : playUrls[useLine.clamp(0, playUrls.length - 1)];
      final directs = _channelDirectUrls(ch);
      if (memUrl.isNotEmpty) {
        url = kotvRewriteEngineLocalUrl(memUrl, engineBase);
        direct = kotvRewriteEngineLocalUrl(
          directs.isEmpty ? '' : directs[useLine.clamp(0, directs.length - 1)],
          engineBase,
        );
        headers = _channelHeaders(ch, line: useLine);
        final drmRaw = ch['drm'];
        drm = drmRaw is Map ? Map<String, dynamic>.from(drmRaw) : null;
        format = '${ch['format'] ?? ''}'.trim();
        lines = playUrls.length;
        lineIdx = useLine;
        lineName = '';
        externalSubs = _channelSubs(ch);
        await stopFut;
      } else {
        if (eng == null) throw Exception('频道无效');
        final playFut = ref.read(apiProvider).livePlay(
              group: eng.group,
              channel: eng.channel,
              line: useLine,
            );
        await stopFut;
        if (!mounted || serial != _playSerial) return;
        final data = await playFut;
        if (!mounted || serial != _playSerial) return;
        url = kotvRewriteEngineLocalUrl('${data['url'] ?? ''}', engineBase);
        direct = kotvRewriteEngineLocalUrl('${data['direct'] ?? ''}', engineBase);
        final hdr = <String, String>{
          for (final e in Map<String, dynamic>.from((data['headers'] as Map?) ?? const {}).entries)
            if ('${e.key}'.trim().isNotEmpty && '${e.value}'.trim().isNotEmpty) '${e.key}': '${e.value}',
        };
        headers = hdr.isEmpty ? null : hdr;
        final drmRaw = data['drm'];
        drm = drmRaw is Map ? Map<String, dynamic>.from(drmRaw) : null;
        format = '${data['format'] ?? ''}'.trim();
        lines = (data['lines'] as int?) ?? (playUrls.isEmpty ? 1 : playUrls.length);
        lineIdx = (data['line'] as int?) ?? useLine;
        lineName = '${data['lineName'] ?? ''}'.trim();
        sourceTitle = '${data['title'] ?? ''}'.trim();
        if (sourceTitle.isEmpty) {
          sourceTitle = '${data['name'] ?? ''}'.trim();
          if (sourceTitle == playChName) sourceTitle = '';
        }
        final playSubs = data['subs'];
        if (playSubs is List && playSubs.isNotEmpty) {
          externalSubs = [
            for (final s in playSubs)
              if (s is Map)
                {
                  'url': '${s['url'] ?? ''}',
                  'name': '${s['name'] ?? ''}',
                  'lang': '${s['lang'] ?? ''}',
                  'format': '${s['format'] ?? ''}',
                },
          ];
        }
        // 引擎解析结果写回内存 urls/directs/subs，同台再切走直开。
        if (url.isNotEmpty) {
          _writeBackLivePlayUrl(
            ch,
            line: useLine,
            url: url,
            direct: direct,
            headers: headers,
            format: format,
            drm: drm,
            subs: externalSubs,
          );
        }
      }
      if (url.isEmpty) throw Exception('空播放地址');
      if (!mounted || serial != _playSerial) return;
      _lines = lines < 1 ? 1 : lines;
      _line = lineIdx;
      _lineName = lineName;
      await _openLiveUrl(
        url,
        serial: serial,
        directUrl: direct,
        headers: headers,
        drm: drm,
        format: format.isEmpty ? null : format,
        externalSubs: externalSubs,
      );
      if (!mounted || serial != _playSerial) return;
      setState(() {
        if (sourceTitle.isNotEmpty) _title = sourceTitle;
        _status = '播放中 · $_title';
        _rememberPlaying(playGroup, chIdx, playGroupName, playChName);
      });
      // 换台亮底栏频道信息，约 5s 收起。
      _flashChannelInfo();
      // 移动端播放器控件：显示后自动隐藏
      if (KotvLayout.useBottomNav(context) || KotvLayout.isCompact(context)) {
        _pulsePortraitChrome();
      }
      unawaited(_saveLiveKeep());
      ref.read(remoteBridgeProvider)?.reportMedia(state: 'playing', title: _title, url: url);
    } catch (e) {
      if (!mounted || serial != _playSerial) return;
      // 失败换线开着且不是最后一条线路时，切下一条。
      final curLine = _line;
      if (_liveAutoChange && _lines > 1 && curLine < _lines - 1) {
        final next = curLine + 1;
        setState(() => _status = '线路失败，自动换线 ${next + 1}/$_lines…');
        await _playChannel(chIdx, line: next);
        return;
      }
      setState(() {
        _status = kotvMpvTeardownStuck || (e is StateError && e.message.contains('播放器异常'))
            ? '播放器异常，请重启应用'
            : '播放失败: $e';
      });
    }
  }

  Future<void> _playCatchup(int progIdx) async {
    // stop → liveCatchup → 立刻 play（与 _playChannel 同序）。
    if (_chIdx < 0) return;
    final serial = ++_playSerial;
    final prevCatchup = _catchup;
    final prevProgIdx = _catchupProgIdx;
    final prevTitle = _title;
    // 先亮回看项，再拉流（换台同理先写 _chIdx）。
    setState(() {
      _status = '加载回看…';
      _catchup = true;
      _catchupProgIdx = progIdx;
      _catchupChrome = true;
      _leftOpen = false;
      _rightOpen = false;
      _epgOpen = false;
    });
    try {
      final eng = _engineChannelRef(_groupIdx, _chIdx);
      if (eng == null) throw Exception('频道无效');
      final stopFut = () async {
        try {
          await _stopPlaybackForLiveZap();
        } catch (_) {}
      }();
      final catchFut = ref.read(apiProvider).liveCatchup(
            group: eng.group,
            channel: eng.channel,
            day: _dayIdx,
            prog: progIdx,
          );
      await stopFut;
      if (!mounted || serial != _playSerial) return;
      final data = await catchFut;
      if (!mounted || serial != _playSerial) return;
      final engineBase = ref.read(apiProvider).baseUrl;
      final url = kotvRewriteEngineLocalUrl('${data['url'] ?? ''}', engineBase);
      if (url.isEmpty) throw Exception('空回看地址');
      final direct = kotvRewriteEngineLocalUrl('${data['direct'] ?? ''}', engineBase);
      final headers = <String, String>{
        for (final e in Map<String, dynamic>.from((data['headers'] as Map?) ?? const {}).entries)
          if ('${e.key}'.trim().isNotEmpty && '${e.value}'.trim().isNotEmpty) '${e.key}': '${e.value}',
      };
      final drmRaw = data['drm'];
      final drm = drmRaw is Map ? Map<String, dynamic>.from(drmRaw) : null;
      List<Map<String, dynamic>>? externalSubs;
      final playSubs = data['subs'];
      if (playSubs is List && playSubs.isNotEmpty) {
        externalSubs = [
          for (final s in playSubs)
            if (s is Map)
              {
                'url': '${s['url'] ?? ''}',
                'name': '${s['name'] ?? ''}',
                'lang': '${s['lang'] ?? ''}',
                'format': '${s['format'] ?? ''}',
              },
        ];
      }
      final catchFormat = '${data['format'] ?? ''}'.trim();
      await _openLiveUrl(
        url,
        serial: serial,
        directUrl: direct,
        headers: headers.isEmpty ? null : headers,
        drm: drm,
        live: true,
        format: catchFormat.isEmpty ? null : catchFormat,
        externalSubs: externalSubs,
      );
      if (!mounted || serial != _playSerial) return;
      setState(() {
        _title = '${data['name'] ?? _title}';
        _status = '回看中 · $_title';
        _catchup = true;
        _catchupProgIdx = progIdx;
        _catchupChrome = true;
        _leftOpen = false;
        _rightOpen = false;
        _epgOpen = false;
      });
      _pulseCatchupChrome();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _catchupChrome) _playFocus.requestFocus();
      });
      ref.read(remoteBridgeProvider)?.reportMedia(state: 'playing', title: _title, url: url);
    } catch (e) {
      if (!mounted || serial != _playSerial) return;
      setState(() {
        _catchup = prevCatchup;
        _catchupProgIdx = prevProgIdx;
        _catchupChrome = prevCatchup;
        _title = prevTitle;
        _status = '回看失败: $e';
      });
    }
  }

  void _pulseCatchupChrome() {
    _catchupHideTimer?.cancel();
    setState(() => _catchupChrome = true);
    _catchupHideTimer = Timer(_liveOverlayHide, () {
      if (mounted && _catchup && !_miniDesktop) {
        setState(() => _catchupChrome = false);
      }
    });
  }

  /// 退出回看，回到当前频道直播。
  Future<void> _exitCatchup() async {
    if (!_catchup) return;
    _catchupHideTimer?.cancel();
    if (_chIdx >= 0) {
      await _playChannel(_chIdx, line: _line);
      return;
    }
    if (!mounted) return;
    setState(() {
      _catchup = false;
      _catchupChrome = false;
      _catchupProgIdx = -1;
    });
  }

  void _toggleCatchupChrome() {
    if (!_catchup) return;
    if (_catchupChrome) {
      _catchupHideTimer?.cancel();
      setState(() => _catchupChrome = false);
    } else {
      _pulseCatchupChrome();
    }
  }

  void _pulsePortraitChrome() {
    _portraitHideTimer?.cancel();
    if (!mounted) return;
    setState(() => _portraitChrome = true);
    _portraitHideTimer = Timer(_liveOverlayHide, () {
      if (mounted && !_miniDesktop) {
        setState(() => _portraitChrome = false);
      }
    });
  }

  void _togglePortraitChrome() {
    if (_playUrl.isNotEmpty) {
      if (_catchup) {
        final wasPlaying = _playback.playing;
        unawaited(_playback.playOrPause());
        if (wasPlaying) {
          _pulseCatchupChrome();
        } else {
          _catchupHideTimer?.cancel();
          setState(() => _catchupChrome = false);
        }
        return;
      }
      // 直播：不暂停，只闪信息 / 竖屏信息条。
      _flashChannelInfo();
      _pulsePortraitChrome();
      return;
    }
    if (_catchup) {
      _toggleCatchupChrome();
      return;
    }
    if (_portraitChrome) {
      _portraitHideTimer?.cancel();
      setState(() => _portraitChrome = false);
    } else {
      _pulsePortraitChrome();
    }
  }

  Future<void> _cast() async {
    await kotvCastPlaying(
      context,
      ref.read(apiProvider),
      playUrl: _playUrl,
      positionMs: _playback.position.inMilliseconds,
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
      onPip: (inPip) {
        _miniDesktop = inPip;
        if (_catchup) _catchupChrome = inPip;
      },
      onEntered: () {
        _miniDesktop = true;
        _leftOpen = false;
        _rightOpen = false;
        if (_catchup) _catchupChrome = true;
      },
    );
  }

  Future<void> _exitMini() {
    return kotvExitMiniPlayback(
      isMounted: () => mounted,
      playback: _playback,
      setState: setState,
      onExited: () => _miniDesktop = false,
    );
  }

  /// 直播横屏本身已是铺满窗口，无需再选「全窗口」。
  /// 桌面/Web：一键占满整块屏幕；移动竖屏：沉浸 + 强制横屏。
  Future<void> _enterLiveFullscreenPreferred() async {
    final kind = (kotvIsDesktop() || kIsWeb)
        ? KotvDesktopFullscreenKind.display
        : KotvDesktopFullscreenKind.window;
    await _enterLiveFullscreen(kind);
  }

  Future<void> _toggleLiveFullscreen() async {
    if (_immersive) {
      await _exitImmersive();
    } else {
      await _enterLiveFullscreenPreferred();
    }
  }

  Future<void> _enterLiveFullscreen([KotvDesktopFullscreenKind desktopFs = KotvDesktopFullscreenKind.window]) async {
    if (_playUrl.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请先选择频道播放')));
      }
      return;
    }
    if (_miniDesktop) await _exitMini();
    if (!mounted) return;
    if (!kotvIsDesktop()) {
      // 手机/平板：全屏强制横屏，侧栏才不会竖着撑满。
      try {
        await SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      } catch (_) {}
    }
    // 先落沉浸布局，再系统全屏（时序收在 kotvEnterSystemFullscreenAfterLayout）。
    setState(() {
      _desktopFs = desktopFs;
      _immersive = true;
      _leftOpen = false;
      _rightOpen = false;
      _chromeVisible = false;
    });
    ref.read(liveImmersiveFullscreenProvider.notifier).state = true;
    if (!mounted) return;
    await kotvEnterSystemFullscreenAfterLayout(desktopFs);
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  Future<void> _exitImmersive() async {
    if (!_immersive) return;
    if (mounted) {
      setState(() {
        _immersive = false;
        _leftOpen = false;
        _rightOpen = false;
        _chromeVisible = false;
      });
      ref.read(liveImmersiveFullscreenProvider.notifier).state = false;
    }
    await kotvExitSystemFullscreen(
      wasDisplayFullscreen: _desktopFs == KotvDesktopFullscreenKind.display,
    );
    if (!mounted) return;
    // 竖屏列表重建后直接停在当前分组、频道和节目。
    _scheduleScrollToCurrent();
  }

  bool get _showDirectOutput => kotvShowDirectOutput(_playback, _decodeMode);

  /// 切换硬解直出：Win7 上换 ANGLE 后端，须换 Player 并按当前进度重开。
  Future<void> _toggleDirectOutput() async {
    final prev = _mpvOpts;
    final next = !_mpvOpts.direct;
    final pos = _playUrl.isNotEmpty ? _playback.position : Duration.zero;
    setState(() => _mpvOpts = _mpvOpts.copyWith(direct: next));
    try {
      await _persistLiveSetting('mpvDirect', kotvWin7DirectNextValue(prev.direct));
    } catch (_) {}
    if (_backend == KotvEmbedBackend.mpv &&
        kotvWin7DirectToggleNeedsNewPlayer(from: prev, nextDirect: next)) {
      await _releaseMpv();
      await _reopenCurrent(pos);
    }
  }

  Future<void> _pickDecode() async {
    if (KotvWinChrome.isNeeded) {
      await KotvWinChrome.showChoiceSheet(
        kind: 'decode',
        title: '解码方式',
        options: KotvWinChrome.decodeModes,
        selectedId: _decodeMode,
      );
      return;
    }
    final v = await pickChoice(context, title: '解码方式', current: _decodeMode, options: const [
      ('自动', 'auto'),
      ('软解码', 'soft'),
      ('硬解码', 'hard'),
    ]);
    if (v == null) return;
    await _applyDecode(v);
  }

  Future<void> _applyDecode(String v) async {
    final prev = _decodeMode;
    final pos = _playUrl.isNotEmpty ? _playback.position : Duration.zero;
    setState(() {
      _decodeMode = v;
      _prefDecodeMode = v;
    });
    if (_backend == KotvEmbedBackend.mpv &&
        kotvMpvNeedsNewPlayer(
          _mpvOpts.copyWith(decodeMode: prev),
          _mpvOpts.copyWith(decodeMode: v),
        )) {
      // 下面按当前进度重开时由 [_playback] 用新的解码方式建 Player。
      await _releaseMpv();
    } else {
      await _playback.setDecodeMode(v);
    }
    try {
      await _persistLiveSetting('playerDecode', v);
    } catch (_) {}
    await _reopenCurrent(pos);
  }

  /// 按当前进度重开正在播的直播或回看（都按 live 起播；进度经 startAt 在首次 play 前恢复）。
  Future<void> _reopenCurrent(Duration pos) async {
    if (_playUrl.isEmpty) return;
    final serial = ++_playSerial;
    await _openLiveUrl(
      _playUrl,
      serial: serial,
      directUrl: _playDirect,
      headers: _playHeaders,
      drm: _playDrm,
      live: true,
      startAt: pos > Duration.zero ? pos : Duration.zero,
    );
  }

  Future<void> _pickRender() async {
    if (KotvWinChrome.isNeeded) {
      await KotvWinChrome.showChoiceSheet(
        kind: 'render',
        title: '渲染方式',
        options: KotvWinChrome.renderModes,
        selectedId: _renderMode,
      );
      return;
    }
    final v = await pickChoice(context, title: '渲染方式', current: _renderMode, options: const [
      ('Surface（推荐，HDR）', 'surface'),
      ('Texture', 'texture'),
    ]);
    if (v == null) return;
    await _applyRender(v);
  }

  Future<void> _applyRender(String v) async {
    setState(() => _renderMode = kotvNormalizePlayerRender(v));
    await _playback.setRenderMode(_renderMode);
    try {
      await _persistLiveSetting('playerRender', _renderMode);
      if (_renderMode == 'texture') {
        await _persistLiveSetting('exoTunneling', 'false');
      }
    } catch (_) {}
  }

  Future<void> _pickPlayer() async {
    if (_pickingPlayer) return;
    _pickingPlayer = true;
    try {
      final navCtx = rootNavigatorKey.currentContext ?? context;
      if (!navCtx.mounted) return;
      final options = await kotvInstalledPlayerOptions(
        live: true,
        playerStatus: () => ref.read(apiProvider).playerStatus(),
      );
      if (!navCtx.mounted || !mounted) return;
      if (KotvWinChrome.isNeeded) {
        await KotvWinChrome.showChoiceSheet(
          kind: 'player',
          title: '直播播放器',
          options: [for (final o in options) (o.$2, o.$1)],
          selectedId: _prefPlayerVal,
        );
        return;
      }
      final v = await pickChoice(navCtx, title: '直播播放器', current: _prefPlayerVal, options: options);
      if (v == null || !mounted) return;
      await _applyPickedPlayer(v);
    } finally {
      _pickingPlayer = false;
    }
  }

  Future<void> _applyPickedPlayer(String v) async {
    final prev = _prefPlayerVal;
    // 内置后端切换：先停旧画面，再改 _playerVal。
    if (v != prev && flutterIsEmbedPlayer(v)) {
      await _stopInactiveBackends(kotvEmbedBackend(v));
      if (!mounted) return;
    }
    setState(() {
      _playerVal = v;
      _prefPlayerVal = v;
    });
    try {
      await _persistLiveSetting('playerLive', v);
    } catch (_) {}
    if (kotvIsExternalPlayer(v) && _playUrl.isNotEmpty) {
      try {
        await _playback.pause();
        if (!mounted) return;
        final result = await kotvLaunchExternalPlayer(
          player: v,
          url: _playUrl,
          headers: _playHeaders,
          title: _title,
          vod: false,
          context: context,
        );
        if (!mounted) return;
        if (!result.opened) {
          await _playback.play();
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已用${flutterPlayerLabel(v)}打开')));
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
      return;
    }
    if (v != prev && _playUrl.isNotEmpty && flutterIsEmbedPlayer(v)) {
      final pos = _playback.position;
      final serial = ++_playSerial;
      await _openLiveUrl(
        _playUrl,
        serial: serial,
        directUrl: _playDirect,
        headers: _playHeaders,
        drm: _playDrm,
        live: true,
        startAt: pos > Duration.zero ? pos : Duration.zero,
      );
      if (!mounted || serial != _playSerial) return;
      setState(() {});
    }
  }

  String get _decodeLabel {
    switch (_decodeMode) {
      case 'soft':
        return '软解码';
      case 'hard':
        return '硬解码';
      default:
        return '自动';
    }
  }

  Timer? _hideTimer;
  int _edgeZone = -1;

  void _cancelHideOverlays() {
    _hideTimer?.cancel();
    _hideTimer = null;
  }

  void _scheduleHideOverlays() {
    // 指针仍在频道栏 / 设置栏 / 底栏上：不计时隐藏。
    if (_pointerInLeftPanel || _pointerInRightPanel || _pointerAtBottom) {
      _cancelHideOverlays();
      return;
    }
    _hideTimer?.cancel();
    _hideTimer = Timer(_liveOverlayHide, () {
      if (!mounted) return;
      if (_pointerInLeftPanel || _pointerInRightPanel || _pointerAtBottom) return;
      setState(() {
        _leftOpen = false;
        _rightOpen = false;
        _epgOpen = false;
        _chromeVisible = false;
        _channelInfoVisible = false;
      });
    });
  }

  void _flashChannelInfo() {
    if (!_leftOpen && !_rightOpen) {
      setState(() {
        _channelInfoVisible = true;
        // 直播只闪信息条；回看可顺带亮播控。
        if (_catchup) {
          _catchupChrome = true;
          _chromeVisible = true;
        }
      });
      _syncWinChrome();
    }
    _scheduleHideOverlays();
  }

  void _openLeft() {
    setState(() {
      _leftOpen = true;
      _rightOpen = false;
      _epgOpen = false;
      _chromeVisible = false;
      _channelInfoVisible = false;
    });
    _syncWinChrome();
    _scheduleHideOverlays();
    if (_programs.isEmpty && _chIdx >= 0) unawaited(_loadEpg());
    _scheduleScrollToCurrent(epg: false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _leftOpen) _focusChannelList();
    });
  }

  void _focusChannelList() {
    if (_chIdx < 0 || _chIdx >= _channels.length) return;
    _chFocus.of('ch:$_chIdx').requestFocus();
  }

  int _highlightedProgram() {
    if (_catchup && _catchupProgIdx >= 0 && _catchupProgIdx < _programs.length) return _catchupProgIdx;
    for (var i = 0; i < _programs.length; i++) {
      if (_programs[i]['now'] == true) return i;
    }
    return _programs.isEmpty ? -1 : 0;
  }

  void _focusProgramList() {
    final i = _highlightedProgram();
    if (i < 0) return;
    _progFocus.of('p:$i').requestFocus();
  }

  void _openRight() {
    setState(() {
      _rightOpen = true;
      _leftOpen = false;
      _chromeVisible = false;
      _channelInfoVisible = false;
    });
    _syncWinChrome();
    _scheduleHideOverlays();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _rightOpen) _rightFocus.requestFocus();
    });
  }

  void _toggleLeft() {
    if (_leftOpen) {
      setState(() {
        _leftOpen = false;
        _epgOpen = false;
      });
      _syncWinChrome();
      return;
    }
    _openLeft();
  }

  void _toggleRight() {
    if (_rightOpen) {
      setState(() => _rightOpen = false);
      _syncWinChrome();
      return;
    }
    _openRight();
  }

  void _onZapDigit(int d) {
    if (_zapDigits.length >= 4) return;
    _zapTimer?.cancel();
    final next = '$_zapDigits$d';
    setState(() => _zapDigits = next);
    _zapTimer = Timer(const Duration(seconds: 2), () {
      final raw = _zapDigits;
      if (mounted) setState(() => _zapDigits = '');
      if (raw.isEmpty) return;
      unawaited(_findChannelByNumber(raw));
    });
  }

  Future<void> _findChannelByNumber(String raw) async {
    final n = int.tryParse(raw);
    if (n == null || n <= 0) return;
    // 按全局 channel.number 扫全部分组（无组内序号兜底）。
    for (var gi = 0; gi < _groups.length; gi++) {
      if (_groupLocked(gi)) continue;
      final chs = ((_groups[gi]['channels'] as List?) ?? []).whereType<Map>().toList();
      for (var ci = 0; ci < chs.length; ci++) {
        final cn = int.tryParse('${chs[ci]['number'] ?? ''}'.trim());
        if (cn == null || cn != n) continue;
        setState(() {
          _groupIdx = gi;
          _chIdx = ci;
        });
        await _playChannel(ci, showList: false);
        return;
      }
    }
  }

  /// 列表/信息条频道号：优先源内全局 number（多为 %03d），空则用组内位次补三位。
  String _channelNumberLabel(Map ch, int indexInGroup) {
    final n = '${ch['number'] ?? ''}'.trim();
    if (n.isNotEmpty) return n;
    return '${indexInGroup + 1}'.padLeft(3, '0');
  }

  /// 频道号列宽：按位数 tabular，避免 PC 全屏/侧栏被裁成半个字。
  double _channelNumColWidth(double fontSize, {int digits = 3}) {
    final ui = LayoutScale.grow(context);
    return (fontSize * 0.62 * digits.clamp(3, 8) + 10).clamp(40.0, 120.0) * ui;
  }

  /// 未选中用省略号。选中才跑马灯，避免频道列表每一行都挂动画。
  Widget _liveListTitle(String text, {required bool selected, required TextStyle style, TextAlign align = TextAlign.left}) {
    if (!selected) {
      return KotvEmojiText(
        text,
        textAlign: align,
        style: style,
      );
    }
    return KotvMarqueeText(text, active: true, textAlign: align, style: style);
  }

  /// 当前列表最长频道号位数（至少 3）。
  int _channelNumDigitsFor(List<Map<String, dynamic>> channels) {
    var max = 3;
    for (var i = 0; i < channels.length; i++) {
      final n = _channelNumberLabel(channels[i], i).length;
      if (n > max) max = n;
    }
    return max.clamp(3, 8);
  }

  /// 侧栏超宽时优先缩 EPG/分组，频道列保底（号码+logo+短台名）。
  ({double groupW, double channelW, double epgW, double epgTabW}) _fitLivePanelCols({
    required double innerMax,
    required double gap1,
    required double gapTab,
    required double gap2,
    required bool epgOpen,
    required double channelFloor,
    required double groupFloor,
    required double epgFloor,
    required double epgTabFloor,
    required double groupW,
    required double channelW,
    required double epgW,
    required double epgTabW,
  }) {
    var g = groupW;
    var c = channelW;
    var e = epgW;
    var t = epgTabW;
    double content() => g + gap1 + c + gapTab + t + (epgOpen ? gap2 + e : 0);
    var excess = content() - innerMax;
    if (excess <= 0) {
      return (groupW: g, channelW: c, epgW: e, epgTabW: t);
    }
    if (epgOpen && excess > 0) {
      final can = (e - epgFloor).clamp(0.0, e);
      final take = excess < can ? excess : can;
      e -= take;
      excess -= take;
    }
    if (excess > 0) {
      final can = (g - groupFloor).clamp(0.0, g);
      final take = excess < can ? excess : can;
      g -= take;
      excess -= take;
    }
    if (excess > 0) {
      final can = (c - channelFloor).clamp(0.0, c);
      final take = excess < can ? excess : can;
      c -= take;
      excess -= take;
    }
    if (excess > 0 && t > epgTabFloor) {
      final can = (t - epgTabFloor).clamp(0.0, t);
      final take = excess < can ? excess : can;
      t -= take;
    }
    return (groupW: g, channelW: c, epgW: e, epgTabW: t);
  }

  void _showLiveChromeAndFocusPlay() {
    if (_catchup) {
      setState(() {
        _leftOpen = false;
        _rightOpen = false;
        _chromeVisible = true;
        _catchupChrome = true;
        _channelInfoVisible = false;
      });
      _scheduleHideOverlays();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_catchupChrome) _playFocus.requestFocus();
      });
      return;
    }
    _openLeft();
  }

  void _bumpLiveChrome() {
    if (_catchup) {
      _pulseCatchupChrome();
    } else if (_leftOpen || _rightOpen || _channelInfoVisible) {
      _scheduleHideOverlays();
    }
  }

  void _selectChannelFromList(int i) {
    _cancelHideOverlays();
    // 再点当前频道：展开 EPG，不重播。
    if (i == _chIdx && !_catchup) {
      setState(() {
        _leftOpen = true;
        _epgOpen = true;
        _rightOpen = false;
        _chromeVisible = false;
      });
      // 指针仍在频道栏内时不计时；离栏 / 离窗再 schedule。
      if (!_pointerInLeftPanel) _scheduleHideOverlays();
      if (_programs.isEmpty) {
        unawaited(_loadEpg());
      } else {
        _scheduleScrollEpgToHighlight();
      }
      return;
    }
    // 点台后收起频道栏，避免挡画面。
    unawaited(_playChannel(i));
  }

  /// 点中间：关菜单，或点画面播/停（左右仍是频道/设置）。
  void _onCenterTap() {
    if (_leftOpen || _rightOpen) {
      setState(() {
        _leftOpen = false;
        _rightOpen = false;
        _chromeVisible = false;
      });
      return;
    }
    _togglePlayPauseOnSurface();
  }

  /// 点播放画面：回看可暂停并出控件；直播只闪频道信息，不停流。
  void _togglePlayPauseOnSurface() {
    if (_playUrl.isEmpty) return;
    if (_catchup) {
      final wasPlaying = _playback.playing;
      unawaited(_playback.playOrPause());
      if (wasPlaying) {
        _pulseCatchupChrome();
        _keepMouseVisible();
      } else {
        _catchupHideTimer?.cancel();
        setState(() => _catchupChrome = false);
        _scheduleHideMouse();
      }
      return;
    }
    _flashChannelInfo();
    _keepMouseVisible();
  }

  /// 双击：未真全屏则占满屏幕；已真全屏则缩回铺满窗口。
  void _onLiveDoubleTap() {
    if (_playUrl.isEmpty) return;
    unawaited(_toggleLiveFullscreen());
  }

  bool get _livePlayerGestures => !KotvLayout.television;

  Future<void> _liveSetPlayerVolume(double percent) => _playback.setVolume(percent);

  void _liveClearSideHud() {
    if (_liveSideGesture == null) return;
    setState(() => _liveSideGesture = null);
  }

  void _liveCancelSeekPreview() {
    if (_liveSeekPreviewBase == null) return;
    setState(() {
      _liveSeekPreviewBase = null;
      _liveSeekPreviewDelta = Duration.zero;
    });
  }

  Duration get _liveSeekPreviewTarget {
    final base = _liveSeekPreviewBase ?? _playback.position;
    final dur = _playback.duration;
    var t = base + _liveSeekPreviewDelta;
    if (dur > Duration.zero && t > dur) t = dur;
    if (t.isNegative) t = Duration.zero;
    return t;
  }

  void _liveCommitSeekPreview() {
    if (_liveSeekPreviewBase == null) return;
    final target = _liveSeekPreviewTarget;
    _liveSeekPreviewBase = null;
    _liveSeekPreviewDelta = Duration.zero;
    unawaited(_playback.seek(target));
    setState(() {});
  }

  void _liveNudgeSeekPreview(Duration step) {
    _liveSeekPreviewBase ??= _playback.position;
    setState(() => _liveSeekPreviewDelta += step);
  }

  void _liveScheduleWheelHudSettle() {
    _liveWheelHudTimer?.cancel();
    _liveWheelHudTimer = Timer(KotvFsGesture.wheelHudSettle, () {
      if (!mounted) return;
      if (_liveSeekPreviewBase != null) _liveCommitSeekPreview();
      _liveClearSideHud();
    });
  }

  Future<void> _livePrimeSide(bool bright) async {
    final want = bright ? KotvFsMode.bright : KotvFsMode.volume;
    final session = bright
        ? await KotvSideGestureSession.beginBright()
        : await KotvSideGestureSession.beginVolume(playerVolume: _playback.volume);
    if (!mounted) return;
    if (_liveGMode != want) return;
    if (session == null) {
      _liveGMode = KotvFsMode.none;
      return;
    }
    setState(() => _liveSideGesture = session);
  }

  void _liveApplySideDrag(double upPositive, double height) {
    final s = _liveSideGesture;
    if (s == null) return;
    s.apply(upPositive, height);
    unawaited(s.flush(setPlayerVolume: _liveSetPlayerVolume));
    setState(() {});
  }

  Future<void> _liveNudgeVolume(double delta) async {
    if (delta == 0) return;
    var s = _liveSideGesture;
    if (s == null || s.kind != 'volume') {
      s = await KotvSideGestureSession.beginVolume(playerVolume: _playback.volume);
      if (!mounted) return;
      setState(() => _liveSideGesture = s);
    }
    s.applyPercentDelta(delta);
    unawaited(s.flush(setPlayerVolume: _liveSetPlayerVolume));
    if (mounted) setState(() {});
    _liveScheduleWheelHudSettle();
  }

  void _liveBeginDragMode(KotvFsMode mode) {
    _liveWheelHudTimer?.cancel();
    if (mode != KotvFsMode.seek && _liveSeekPreviewBase != null) {
      _liveCancelSeekPreview();
    }
    if (mode != KotvFsMode.bright && mode != KotvFsMode.volume) {
      _liveClearSideHud();
    }
    switch (mode) {
      case KotvFsMode.seek:
        _liveGMode = KotvFsMode.seek;
        _liveSeekPreviewBase = _playback.position;
        _liveSeekPreviewDelta = Duration.zero;
        setState(() {});
        break;
      case KotvFsMode.bright:
        _liveGMode = KotvFsMode.bright;
        unawaited(_livePrimeSide(true));
        break;
      case KotvFsMode.volume:
        _liveGMode = KotvFsMode.volume;
        unawaited(_livePrimeSide(false));
        break;
      case KotvFsMode.channel:
        _liveGMode = KotvFsMode.channel;
        break;
      case KotvFsMode.none:
      case KotvFsMode.ep:
      case KotvFsMode.pinch:
        break;
    }
  }

  void _liveHandleTapAt(Offset local, Size size) {
    final now = DateTime.now();
    final last = _liveLastTapAt;
    _liveLastTapAt = now;
    if (last != null && now.difference(last) < kDoubleTapTimeout) {
      _liveLastTapAt = null;
      _onLiveDoubleTap();
      return;
    }
    switch (KotvFsGesture.liveTapZone(local.dx, size.width)) {
      case 0:
        _toggleLeft();
        break;
      case 2:
        _toggleRight();
        break;
      default:
        _onCenterTap();
        break;
    }
  }

  void _onLiveFsPointerDown(PointerDownEvent e) {
    if (e.buttons == kSecondaryMouseButton) {
      kotvHandleAppBack?.call();
      return;
    }
    if (e.buttons != kPrimaryButton) return;
    if (_leftOpen || _rightOpen || _epgOpen) return;
    // 电视：只保留短点三分区，不启拖/滚手势。
    if (!_livePlayerGestures) {
      _liveSwipePointer = e.pointer;
      _liveSwipeDownAt = e.position;
      _liveGMode = KotvFsMode.none;
      return;
    }
    _livePointers[e.pointer] = e.position;
    final touchLike = KotvFsGesture.isTouchLike(e.kind);
    final size = MediaQuery.sizeOf(context);
    if (touchLike && _livePointers.length >= 2) {
      final pts = _livePointers.values.toList();
      _liveGMode = KotvFsMode.pinch;
      _livePinchStartScale = _livePinchScale;
      _livePinchSpan0 = (pts[0] - pts[1]).distance.clamp(1.0, 10000.0);
      _livePinchFocal = Offset((pts[0].dx + pts[1].dx) / 2, (pts[0].dy + pts[1].dy) / 2);
      _liveSwipePointer = null;
      return;
    }
    if (_liveSwipePointer != null) return;
    if (touchLike && KotvFsGesture.isEdge(e.position, size)) return;
    _liveWheelHudTimer?.cancel();
    _liveSwipePointer = e.pointer;
    _liveSwipeDownAt = e.position;
    _liveGMode = KotvFsMode.none;
  }

  void _onLiveFsPointerMove(PointerMoveEvent e) {
    if (!_livePlayerGestures) return; // 电视忽略拖移
    if (_livePointers.containsKey(e.pointer)) {
      _livePointers[e.pointer] = e.position;
    }
    if (_liveGMode == KotvFsMode.pinch && _livePointers.length >= 2) {
      final pts = _livePointers.values.toList();
      final span = (pts[0] - pts[1]).distance.clamp(1.0, 10000.0);
      final next = (_livePinchStartScale * span / _livePinchSpan0).clamp(1.0, 5.0);
      _livePinchFocal = Offset((pts[0].dx + pts[1].dx) / 2, (pts[0].dy + pts[1].dy) / 2);
      setState(() => _livePinchScale = next);
      return;
    }
    if (e.pointer != _liveSwipePointer || _liveSwipeDownAt == null) return;
    final total = e.position - _liveSwipeDownAt!;
    final size = MediaQuery.sizeOf(context);
    if (_liveGMode == KotvFsMode.none) {
      if (total.distance < kTouchSlop) return;
      final mode = KotvFsGesture.classifyLiveDrag(
        total: total,
        downX: _liveSwipeDownAt!.dx,
        width: size.width,
        catchup: _catchup,
      );
      if (mode == KotvFsMode.none) return;
      _liveBeginDragMode(mode);
      return;
    }
    switch (_liveGMode) {
      case KotvFsMode.seek:
        final ms = (total.dx * KotvFsGesture.seekMsPerPx).round();
        setState(() {
          _liveSeekPreviewBase ??= _playback.position;
          _liveSeekPreviewDelta = Duration(milliseconds: ms);
        });
        break;
      case KotvFsMode.bright:
      case KotvFsMode.volume:
        _liveApplySideDrag(-total.dy, size.height);
        break;
      case KotvFsMode.channel:
      case KotvFsMode.none:
      case KotvFsMode.ep:
      case KotvFsMode.pinch:
        // channel：位移在抬手 fling；ep/pinch 不在直播拖分区。
        break;
    }
  }

  void _endLiveFsPointer(int pointer, {required bool cancelled, Offset? upPos}) {
    _livePointers.remove(pointer);
    if (_liveGMode == KotvFsMode.pinch) {
      if (_livePointers.length < 2) _liveGMode = KotvFsMode.none;
      return;
    }
    if (pointer != _liveSwipePointer) return;
    final downAt = _liveSwipeDownAt;
    final mode = _liveGMode;
    final total = (downAt != null && upPos != null) ? upPos - downAt : Offset.zero;
    _liveSwipePointer = null;
    _liveSwipeDownAt = null;
    _liveGMode = KotvFsMode.none;
    switch (mode) {
      case KotvFsMode.seek:
        if (!cancelled && _liveSeekPreviewBase != null) {
          _liveCommitSeekPreview();
        } else {
          _liveCancelSeekPreview();
        }
        break;
      case KotvFsMode.bright:
      case KotvFsMode.volume:
        _liveClearSideHud();
        break;
      case KotvFsMode.channel:
        if (!cancelled) {
          final sign = KotvFsGesture.liveChannelFlingSign(total);
          if (sign != null) {
            final delta = _liveInvert ? -sign : sign;
            unawaited(_stepChannel(delta: delta));
          }
        }
        break;
      case KotvFsMode.none:
        if (!cancelled && downAt != null && upPos != null) {
          final dist = (upPos - downAt).distance;
          if (dist < kTouchSlop) {
            _liveHandleTapAt(upPos, MediaQuery.sizeOf(context));
          }
        }
        break;
      case KotvFsMode.ep:
      case KotvFsMode.pinch:
        break;
    }
  }

  void _onLiveFsPointerUp(PointerUpEvent e) {
    _endLiveFsPointer(e.pointer, cancelled: false, upPos: e.position);
  }

  void _onLiveFsPointerCancel(PointerCancelEvent e) {
    _endLiveFsPointer(e.pointer, cancelled: true);
  }

  void _onLiveFsPointerSignal(PointerSignalEvent e) {
    if (!_livePlayerGestures || e is! PointerScrollEvent) return;
    if (_leftOpen || _rightOpen || _epgOpen) return;
    if (_liveGMode == KotvFsMode.pinch) return;
    if (_liveSwipePointer != null && _liveGMode != KotvFsMode.none) return;
    final kind = KotvFsGesture.classifyLiveScroll(
      dx: e.scrollDelta.dx,
      dy: e.scrollDelta.dy,
      shift: KotvFsGesture.shiftPressed,
      catchup: _catchup,
    );
    switch (kind) {
      case KotvFsScrollKind.volume:
        unawaited(_liveNudgeVolume(KotvFsGesture.volumeDeltaFromScrollDy(e.scrollDelta.dy)));
        break;
      case KotvFsScrollKind.seek:
        _liveNudgeSeekPreview(
          KotvFsGesture.seekDeltaFromScroll(
            dx: e.scrollDelta.dx,
            dy: e.scrollDelta.dy,
            shift: KotvFsGesture.shiftPressed,
          ),
        );
        _liveScheduleWheelHudSettle();
        break;
      case KotvFsScrollKind.none:
        break;
    }
  }

  void _onLiveFsPanZoomUpdate(PointerPanZoomUpdateEvent e) {
    if (!_livePlayerGestures) return;
    if (_leftOpen || _rightOpen || _epgOpen) return;
    if (_liveGMode == KotvFsMode.pinch) return;
    if (_liveSwipePointer != null && _liveGMode != KotvFsMode.none) return;
    final kind = KotvFsGesture.classifyLiveScroll(
      dx: e.localPanDelta.dx,
      dy: e.localPanDelta.dy,
      shift: false,
      catchup: _catchup,
    );
    switch (kind) {
      case KotvFsScrollKind.volume:
        unawaited(_liveNudgeVolume(KotvFsGesture.volumeDeltaFromScrollDy(e.localPanDelta.dy)));
        break;
      case KotvFsScrollKind.seek:
        _liveNudgeSeekPreview(
          KotvFsGesture.seekDeltaFromScroll(
            dx: e.localPanDelta.dx,
            dy: e.localPanDelta.dy,
            shift: false,
          ),
        );
        _liveScheduleWheelHudSettle();
        break;
      case KotvFsScrollKind.none:
        break;
    }
  }

  void _onHover(PointerHoverEvent e, BoxConstraints c) {
    const hot = KotvFsGesture.desktopEdgeHover;
    var zone = -1;
    if (e.localPosition.dx <= hot) {
      zone = 0;
    } else if (e.localPosition.dx >= c.maxWidth - hot) {
      zone = 2;
    }
    if (zone == _edgeZone) return;
    _edgeZone = zone;
    if (zone == 0) {
      _openLeft();
    } else if (zone == 2) {
      _openRight();
    }
  }

  void _keepMouseVisible() {
    _cursorHideTimer?.cancel();
    if (_mouseCursor != SystemMouseCursors.basic && mounted) {
      setState(() => _mouseCursor = SystemMouseCursors.basic);
    }
  }

  void _scheduleHideMouse() {
    _cursorHideTimer?.cancel();
    if (_leftOpen || _rightOpen || _pointerAtBottom) return;
    _cursorHideTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      if (_leftOpen || _rightOpen || _pointerAtBottom) return;
      if (_mouseCursor == SystemMouseCursors.none) return;
      setState(() => _mouseCursor = SystemMouseCursors.none);
    });
  }

  void _onLivePointerMove(PointerHoverEvent e, BoxConstraints c, {bool sides = true, bool portrait = false}) {
    if (sides) _onHover(e, c);
    _keepMouseVisible();
    final atBottom = e.localPosition.dy >= c.maxHeight - 80;
    if (atBottom != _pointerAtBottom) {
      _pointerAtBottom = atBottom;
      if (atBottom) {
        if (portrait) {
          _portraitHideTimer?.cancel();
          if (!_portraitChrome) setState(() => _portraitChrome = true);
        }
        if (_catchup) {
          _catchupHideTimer?.cancel();
          if (!_catchupChrome) setState(() => _catchupChrome = true);
        } else if (!portrait && !_leftOpen && !_rightOpen) {
          // 直播：底边移入只亮频道信息，不拉播控。
          if (!_channelInfoVisible) setState(() => _channelInfoVisible = true);
          _scheduleHideOverlays();
        }
      } else if (_playback.playing) {
        if (portrait) {
          _pulsePortraitChrome();
        }
        if (_catchup) {
          _pulseCatchupChrome();
        } else if (!portrait && _channelInfoVisible && !_leftOpen && !_rightOpen) {
          _scheduleHideOverlays();
        }
      }
    }
    if (!_pointerAtBottom) _scheduleHideMouse();
  }

  void _onLivePointerExit() {
    _edgeZone = -1;
    _pointerAtBottom = false;
    _pointerInLeftPanel = false;
    _pointerInRightPanel = false;
    _scheduleHideMouse();
    _scheduleHideOverlays();
  }

  void _selectEpgDay(int i, {bool resetHide = false}) {
    if (resetHide) _cancelHideOverlays();
    final progs = (((_epgDays[i]['list'] as List?) ?? [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList());
    setState(() {
      _dayIdx = i;
      _programs = progs;
    });
    _scheduleScrollEpgToHighlight();
  }

  Widget _epgDayTabs({
    required bool land,
    double? height,
    double? pillWidth,
    double? pillHeight,
    double? fontSize,
    EdgeInsetsGeometry? padding,
    bool resetHideOnSelect = false,
  }) {
    if (_epgDays.length <= 1) return const SizedBox.shrink();
    return SizedBox(
      height: height ?? (land ? 24.0 : 28.0),
      child: HScrollList(
        scrollToIndex: _dayIdx,
        itemStride: (pillWidth ?? (land ? 56.0 : 72.0)) * LayoutScale.layoutOf(context) + (land ? 3.0 : 6.0),
        padding: padding,
        itemCount: _epgDays.length,
        separatorBuilder: (_, __) => SizedBox(width: land ? 3 : 6),
        itemBuilder: (_, i) {
          final d = '${_epgDays[i]['date'] ?? 'D$i'}';
          final label = d.length >= 10 ? d.substring(5, 10) : d;
          return AppPill(
            label: label,
            width: pillWidth ?? (land ? 56.0 : 72.0),
            height: pillHeight ?? (land ? 22.0 : 30.0),
            fontSize: fontSize ?? (land ? 10.0 : 12.0),
            selected: i == _dayIdx,
            onTap: () => _selectEpgDay(i, resetHide: resetHideOnSelect),
          );
        },
      ),
    );
  }

  Widget _epgProgramTile(
    int i, {
    required bool land,
    bool portrait = false,
  }) {
    final prog = _programs[i];
    final now = prog['now'] == true;
    final canCatchup = prog['catchup'] == true;
    final playing = _catchup && i == _catchupProgIdx;
    // 回看时只高亮回看项；直播时高亮「正在播出」。
    final sel = playing || (!_catchup && now);
    final start = '${prog['start'] ?? ''}'.trim();
    final title = '${prog['title'] ?? ''}'.trim();
    final fallback = '${prog['label'] ?? ''}'.trim();
    final label = title.isNotEmpty ? title : fallback;
    void activate() {
      _cancelHideOverlays();
      if (canCatchup) unawaited(_playCatchup(i));
    }

    if (portrait) {
      final p = KotvPalette.of(context);
      return Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: TvFocus(
          focusNode: _progFocus.of('p:$i'),
          borderRadius: 8,
          onPressed: canCatchup ? activate : null,
          child: Material(
              color: _liveProgramColor(p, sel: sel, playing: playing),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    if (start.isNotEmpty)
                      SizedBox(
                        width: 44,
                        child: Text(
                          start,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: sel ? Colors.white : p.fg.withOpacity(0.75),
                            fontSize: 12,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    Expanded(
                      child: KotvMarqueeText(
                        label,
                        active: sel,
                        style: TextStyle(
                          color: sel ? Colors.white : p.fg,
                          fontSize: 13,
                          fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                        ),
                      ),
                    ),
                    if (playing)
                      Text('回看中', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700))
                    else if (canCatchup)
                      Text('回看', style: TextStyle(color: p.primary, fontSize: 12, fontWeight: FontWeight.w700))
                    else if (now && !_catchup)
                      Text('正在播出', style: TextStyle(color: p.muted, fontSize: 12)),
                  ],
                ),
              ),
            ),
        ),
      );
    }

    final p = KotvPalette.of(context);
    final ui = LayoutScale.grow(context);
    return Padding(
      padding: EdgeInsets.only(bottom: (land ? 2 : 4) * ui),
      child: TvFocus(
        focusNode: _progFocus.of('p:$i'),
        borderRadius: 6 * ui,
        onPressed: canCatchup ? activate : null,
        child: Material(
            color: _liveProgramColor(p, sel: sel, playing: playing),
            borderRadius: BorderRadius.circular(6 * ui),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: (land ? 6 : 8) * ui,
                vertical: (land ? 5 : 8) * ui,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (start.isNotEmpty)
                    SizedBox(
                      width: (land ? 38 : 44) * ui,
                      child: Text(
                        start,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: sel ? Colors.white : p.fg.withOpacity(0.75),
                          fontSize: land ? 11 : 12,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  Expanded(
                    child: KotvMarqueeText(
                      '$label${playing ? ' · 回看中' : (canCatchup ? ' · 回看' : '')}',
                      active: sel,
                      style: TextStyle(
                        color: sel ? Colors.white : p.fg,
                        fontSize: 12,
                        height: 1.2,
                        fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ),
    );
  }

  String get _currentLogo {
    final ch = _playingChannel;
    if (ch == null) return '';
    return '${ch['logo'] ?? ''}';
  }

  /// 仅「正在播出」；无 now 不回退到首条（避免 00:xx 假当前）。
  Map<String, dynamic>? get _currentProgram {
    for (final p in _programs) {
      if (p['now'] == true) return p;
    }
    return null;
  }

  /// `DateTime.now().toIso8601String()` 是 UTC 日期，不能用来对 EPG 日。
  static String _localDateString([DateTime? n]) {
    final d = n ?? DateTime.now();
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }

  String get _programTimeLabel {
    final p = _currentProgram;
    if (p == null) return '';
    final start = '${p['start'] ?? ''}'.trim();
    final end = '${p['end'] ?? ''}'.trim();
    if (start.isEmpty && end.isEmpty) return '';
    if (start.isEmpty) return end;
    if (end.isEmpty) return start;
    return '$start ~ $end';
  }

  String get _programTitleLabel {
    final p = _currentProgram;
    if (p == null) return '';
    final title = '${p['title'] ?? ''}'.trim();
    if (title.isNotEmpty) return title;
    return '${p['label'] ?? ''}'.trim();
  }

  String get _channelNum {
    final ch = _playingChannel;
    if (ch == null) return '--';
    return _channelNumberLabel(ch, _playChIdx);
  }

  String get _lineLabel {
    if (_playChIdx < 0 || _lines <= 1) return '';
    if (_lineName.isNotEmpty) return '$_lineName (${_line + 1}/$_lines)';
    return '线路 ${_line + 1}/$_lines';
  }

  /// 侧栏或回看播控打开时，方向键交给焦点；频道信息条不挡换台。
  bool get _liveUiOpen =>
      _leftOpen || _rightOpen || (_catchup && _catchupChrome);

  void _seekByRemote(Duration delta) {
    final next = _playback.position + delta;
    unawaited(_playback.seek(next.isNegative ? Duration.zero : next));
    // 回看/直播 seek 不亮整套播控；换台频道信息条由换台路径单独 pulse。
    if (_catchup && _catchupChrome) {
      _scheduleHideOverlays();
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final isDown = event is KeyDownEvent;
    final isRepeat = event is KeyRepeatEvent;
    if (!isDown && !isRepeat) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final chs = _channels;

    if (kotvIsBackKey(key)) {
      if (!isDown) return KeyEventResult.ignored;
      if (_handleLiveBack()) return KeyEventResult.handled;
      return KeyEventResult.ignored;
    }

    // 根 Navigator 上的 pickChoice 不会使本页 ModalRoute 失 current，勿在弹窗开着时换台/切线。
    if (_livePopupOpen()) return KeyEventResult.ignored;

    // 数字切台：控件开着也可用（常见盒子习惯）；仅 Down，勿 KeyRepeat 连发。
    final digit = kotvDigitFromKey(key);
    if (digit != null) {
      if (!isDown) return KeyEventResult.ignored;
      _onZapDigit(digit);
      return KeyEventResult.handled;
    }

    // 有面板/底栏：方向键交给 TvFocus；快退/快进才 seek（勿抢选台横移）。
    if (_liveUiOpen) {
      if (kotvIsMenuKey(key)) {
        if (!isDown) return KeyEventResult.ignored;
        _toggleRight();
        return KeyEventResult.handled;
      }
      if (kotvIsSettingsKey(key)) {
        if (!isDown) return KeyEventResult.ignored;
        _openRight();
        return KeyEventResult.handled;
      }
      if (_catchup && kotvIsMediaRewind(key)) {
        _seekByRemote(-_liveCatchupSeekStep);
        return KeyEventResult.handled;
      }
      if (_catchup && kotvIsMediaFastForward(key)) {
        _seekByRemote(_liveCatchupSeekStep);
        return KeyEventResult.handled;
      }
      if (kotvIsEnterKey(key) ||
          kotvIsMediaPlayPause(key) ||
          kotvIsDpadNavKey(key)) {
        if (!isDown) return KeyEventResult.ignored;
        if (kotvPrimaryIsEmptyOr(node)) {
          _restoreLiveRemoteFocus();
          return KeyEventResult.handled;
        }
        _bumpLiveChrome();
        return KeyEventResult.ignored;
      }
      return KeyEventResult.ignored;
    }

    // —— 控件全隐：一键一义 ——
    // 菜单 → 右侧设置；OK → 频道栏；设置 → 设置栏；上下换台；左右换线（回看则 seek）。
    // 鼠标右键仍走返回，不在此处理。菜单/返回/设置/OK 仅 Down；上下换台与左右 seek/换线接受 KeyRepeat。
    if (kotvIsMenuKey(key)) {
      if (!isDown) return KeyEventResult.ignored;
      _toggleRight();
      return KeyEventResult.handled;
    }
    if (_catchup) {
      if (kotvIsEnterKey(key) || kotvIsMediaPlayPause(key)) {
        if (!isDown) return KeyEventResult.ignored;
        _openLeft();
        return KeyEventResult.handled;
      }
      if (kotvIsLeftKey(key) || kotvIsMediaRewind(key)) {
        _seekByRemote(-_liveCatchupSeekStep);
        return KeyEventResult.handled;
      }
      if (kotvIsRightKey(key) || kotvIsMediaFastForward(key)) {
        _seekByRemote(_liveCatchupSeekStep);
        return KeyEventResult.handled;
      }
      if (kotvIsSettingsKey(key)) {
        if (!isDown) return KeyEventResult.ignored;
        _openRight();
        return KeyEventResult.handled;
      }
      // 时移中上下仍可换台
    }
    if (kotvIsSettingsKey(key)) {
      if (!isDown) return KeyEventResult.ignored;
      _openRight();
      return KeyEventResult.handled;
    }
    if (kotvIsEnterKey(key) || kotvIsMediaPlayPause(key)) {
      if (!isDown) return KeyEventResult.ignored;
      _openLeft();
      return KeyEventResult.handled;
    }
    if (kotvIsUpKey(key)) {
      if (chs.isEmpty) return KeyEventResult.handled;
      unawaited(_stepChannel(delta: _liveInvert ? 1 : -1));
      return KeyEventResult.handled;
    }
    if (kotvIsDownKey(key)) {
      if (chs.isEmpty) return KeyEventResult.handled;
      unawaited(_stepChannel(delta: _liveInvert ? -1 : 1));
      return KeyEventResult.handled;
    }
    if (kotvIsLeftKey(key) || kotvIsMediaRewind(key)) {
      if (_chIdx >= 0 && _lines > 1) {
        unawaited(_playChannel(_chIdx, line: (_line - 1 + _lines) % _lines));
      }
      return KeyEventResult.handled;
    }
    if (kotvIsRightKey(key) || kotvIsMediaFastForward(key)) {
      if (_chIdx >= 0 && _lines > 1) {
        unawaited(_playChannel(_chIdx, line: (_line + 1) % _lines));
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _buildLiveCatchupChrome({
    VoidCallback? onBump,
    bool miniActive = false,
    bool translucent = false,
    bool autofocusPlay = false,
    bool offerFullscreen = true,
    VoidCallback? onMini,
    ValueChanged<KotvDesktopFullscreenKind>? onExpand,
  }) {
    return LiveCatchupChrome(
      player: _playback,
      miniActive: miniActive,
      translucent: translucent,
      autofocusPlay: autofocusPlay,
      playFocusNode: autofocusPlay ? _playFocus : null,
      onBump: onBump,
      showSeek: _catchup,
      playerLabel: flutterPlayerLabel(_playerVal),
      decodeLabel: _decodeLabel,
      offerFullscreenChoice: offerFullscreen ? null : false,
      fullscreenActive: _immersive,
      onPersistSetting: (k, v) => _persistLiveSetting(k, v),
      onCast: () => unawaited(_cast()),
      onMini: onMini,
      onExpand: onExpand,
      onPlayer: kotvCanSwitchPlayer(live: true) ? () => unawaited(_pickPlayer()) : null,
      onDecode: () => unawaited(_pickDecode()),
      onDirectOutput: _showDirectOutput ? () => unawaited(_toggleDirectOutput()) : null,
      directOutputOn: _playback.directOutputActive,
      onScale: () => unawaited(_cycleLiveScale()),
      scaleLabel: _liveScaleLabel(_liveScale),
      onAcross: _onLiveAcross,
      acrossOn: _liveAcross,
      onInvert: _onLiveInvert,
      invertOn: _liveInvert,
      onFailSwitch: _onLiveFailSwitch,
      failSwitchOn: _liveAutoChange,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Win7：画面区几何要等本帧布局完再量（窗口缩放、进出全屏、横竖切换都只走 build）。
    if (KotvWinChrome.isNeeded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncWinChrome();
      });
    }
    if (!_loading && _sources.isEmpty && _error == null) {
      return Column(
        children: [
          LibraryTopBar(
            onBack: () => kotvPageBack(ref),
            onSearch: () => goKotvPage(ref, KotvPage.search),
            onProfile: () => goKotvPage(ref, KotvPage.profile),
            onNews: () => showLatestNews(context, ref),
            title: '直播',
          ),
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('请先在设置中配置直播源，或在点播配置中包含 lives',
                      style: TextStyle(color: KotvPalette.of(context).muted, fontSize: 16)),
                  const SizedBox(height: 16),
                  AppPill(label: '打开设置', width: 140, selected: true, onTap: () => goKotvPage(ref, KotvPage.settings)),
                  const SizedBox(height: 10),
                  AppPill(
                    label: '配置直播源',
                    width: 140,
                    onTap: () async {
                      await showAddLiveDialog(context, ref);
                      await _bootstrap();
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    if (_miniDesktop) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: DragToMoveArea(
          child: MiniHoverShell(
            player: _playback,
            video: _buildSharedLiveVideo(),
            chrome: _buildLiveCatchupChrome(
              miniActive: true,
              translucent: true,
              onMini: () => unawaited(_exitMini()),
            ),
          ),
        ),
      );
    }

    // 竖屏 / 窄窗：上播放器 + 下频道列表（移动端布局）。沉浸全屏则走下方左右菜单。
    if (!_immersive && (KotvLayout.useBottomNav(context) || KotvLayout.isCompact(context))) {
      return _buildPortraitLive();
    }

    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: ColoredBox(
        key: _winLiveSurfaceKey,
        color: Colors.black,
        child: LayoutBuilder(
          builder: (context, c) {
            return MouseRegion(
              cursor: _mouseCursor,
              onHover: (e) => _onLivePointerMove(e, c),
              onExit: (_) => _onLivePointerExit(),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Transform(
                    alignment: Alignment.center,
                    transform: KotvFsGesture.pinchTransform(
                      scale: _livePinchScale,
                      focal: _livePinchFocal,
                      size: Size(c.maxWidth, c.maxHeight),
                    ),
                    child: _buildSharedLiveVideo(),
                  ),
                  // Android Hybrid：起播/换台无帧时盖黑防叠影；桌面 Texture 不挂此层。
                  _buildLiveSurfaceCover(),
                  _buildLiveDanmakuOverlay(),
                  // 画面、挡帧、弹幕铺满（含刘海一侧）；控件放进 SafeArea 避开刘海与手势条。
                  SafeArea(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        // Win7：转圈与网速由原生壳画（KotvWinBufferText）。
                        if (!KotvWinChrome.isNeeded)
                          KotvBufferingOverlay(
                            player: _playback,
                            force: _status.contains('解析') ||
                                _status.contains('加载') ||
                                _status.contains('缓冲') ||
                                _loading,
                          ),
                        if (_zapDigits.isNotEmpty)
                          Positioned(
                            right: 36,
                            top: 48,
                            child: IgnorePointer(
                              child: Text(
                                _zapDigits,
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.92),
                                  fontSize: 56,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 2,
                                  shadows: const [Shadow(color: Colors.black54, blurRadius: 8)],
                                ),
                              ),
                            ),
                          ),
                        if (_error != null) Center(child: Text(_error!, style: const TextStyle(color: Colors.white70))),
                        // 触屏/鼠标/触控板：拖分区手势；抬手短点仍左栏/中播停/右设置。
                        Positioned.fill(
                          child: Listener(
                            behavior: HitTestBehavior.translucent,
                            onPointerDown: _onLiveFsPointerDown,
                            onPointerMove: _onLiveFsPointerMove,
                            onPointerUp: _onLiveFsPointerUp,
                            onPointerCancel: _onLiveFsPointerCancel,
                            onPointerSignal: _onLiveFsPointerSignal,
                            onPointerPanZoomUpdate: _onLiveFsPanZoomUpdate,
                          ),
                        ),
                        if (_liveSideGesture != null)
                          IgnorePointer(
                            child: Center(
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                decoration: BoxDecoration(
                                  color: Colors.black.withOpacity(0.62),
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      _liveSideGesture!.kind == 'bright'
                                          ? Icons.brightness_6_rounded
                                          : Icons.volume_up_rounded,
                                      color: Colors.white,
                                      size: 22,
                                    ),
                                    const SizedBox(width: 10),
                                    Text(
                                      '${_liveSideGesture!.percent.round()}%',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 16,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        if (_liveSeekPreviewBase != null)
                          IgnorePointer(
                            child: Center(
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
                                decoration: BoxDecoration(
                                  color: Colors.black.withOpacity(0.72),
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      _liveSeekPreviewDelta >= Duration.zero
                                          ? Icons.fast_forward_rounded
                                          : Icons.fast_rewind_rounded,
                                      color: Colors.white,
                                      size: 28,
                                    ),
                                    const SizedBox(width: 12),
                                    Text(
                                      '${fmtBoundedPlayerTime(_liveSeekPreviewTarget)} / ${fmtBoundedPlayerTime(_playback.duration)}',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 18,
                                        fontWeight: FontWeight.w700,
                                        fontFeatures: [FontFeature.tabularFigures()],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        if (_playUrl.isNotEmpty && !_leftOpen && !_rightOpen)
                          if (_catchup)
                            ExcludeFocus(
                              child: CenterPlayPauseButton(
                                player: _playback,
                                hideWhenBuffering: true,
                                enabled: !_loading &&
                                    !_status.contains('解析') &&
                                    !_status.contains('加载') &&
                                    !_status.contains('缓冲'),
                              ),
                            ),
                        if ((_catchup && _catchupChrome) && !_leftOpen && !_rightOpen)
                          Positioned(
                            left: KotvLayout.isLandscapeCompact(context) ? 10 : 16,
                            top: KotvLayout.isLandscapeCompact(context) ? 8 : 12,
                            child: AppPill(
                              label: _immersive
                                  ? '退出全屏'
                                  : '返回直播',
                              width: KotvLayout.isLandscapeCompact(context)
                                  ? (!_immersive ? 96.0 : 78.0)
                                  : (!_immersive ? 110.0 : 96.0),
                              height: KotvLayout.isLandscapeCompact(context) ? 28 : 36,
                              fontSize: KotvLayout.isLandscapeCompact(context) ? 12 : 14,
                              onTap: () {
                                if (_immersive) {
                                  unawaited(_exitImmersive());
                                } else {
                                  unawaited(_exitCatchup());
                                }
                              },
                            ),
                          ),
                        if (!_catchup && _immersive && _channelInfoVisible && !_leftOpen && !_rightOpen)
                          Positioned(
                            left: KotvLayout.isLandscapeCompact(context) ? 10 : 16,
                            top: KotvLayout.isLandscapeCompact(context) ? 8 : 12,
                            child: AppPill(
                              label: '退出全屏',
                              width: KotvLayout.isLandscapeCompact(context) ? 78.0 : 96.0,
                              height: KotvLayout.isLandscapeCompact(context) ? 28 : 36,
                              fontSize: KotvLayout.isLandscapeCompact(context) ? 12 : 14,
                              onTap: () => unawaited(_exitImmersive()),
                            ),
                          ),
                        // Win7：左栏由原生壳承接，勿再建 Flutter 面板（会被 HWND 挡住）。
                        if (_leftOpen && !KotvWinChrome.isNeeded)
                          Positioned(
                            left: 0,
                            top: 0,
                            bottom: 0,
                            child: MouseRegion(
                              onEnter: (_) {
                                _pointerInLeftPanel = true;
                                _cancelHideOverlays();
                              },
                              onExit: (_) {
                                _pointerInLeftPanel = false;
                                _scheduleHideOverlays();
                              },
                              child: Material(
                                color: KotvPalette.of(context).dialogBg,
                                child: Builder(builder: (context) {
                                  final p = KotvPalette.of(context);
                                  final screenW = c.maxWidth;
                                  final land = KotvLayout.isLandscapeCompact(context);
                                  final ui = LayoutScale.grow(context);
                                  var groupW = (land ? 112.0 : 136.0) * ui;
                                  var channelW = (land ? 248.0 : 280.0) * ui;
                                  var epgW = (land ? 200.0 : 260.0) * ui;
                                  var epgTabW = (land ? 28.0 : 32.0) * ui;
                                  final padH = (land ? 6.0 : 8.0) * 2 * ui;
                                  final gap1 = (land ? 4.0 : 6.0) * ui;
                                  final gapTab = (land ? 4.0 : 6.0) * ui;
                                  final gap2 = 6.0 * ui;
                                  final pillH = land ? 30.0 : 36.0;
                                  final chH = (land ? 36.0 : 48.0) * ui;
                                  final groupStride = pillH * LayoutScale.layoutOf(context) + (land ? 4.0 : 6.0) * ui;
                                  final channelStride = chH + (land ? 2.0 : 4.0) * ui;
                                  const epgFont = 12.0;
                                  final epgStride = _oneLine(
                                        context,
                                        const TextStyle(fontSize: epgFont, height: 1.2, fontWeight: FontWeight.w700),
                                      ) +
                                      (land ? 10.0 : 16.0) * ui +
                                      (land ? 2.0 : 4.0) * ui;
                                  _pinList(_groupScroll, _groupIdx, groupStride, _groupStride, _pinnedGroup);
                                  _pinList(_channelScroll, _channelListIndex(), channelStride, _channelStride, _pinnedChannel);
                                  _pinList(_epgScroll, _epgHighlightIndex(), epgStride, _epgStride, _pinnedEpg);
                                  _pinnedGroup = _groupIdx;
                                  _pinnedChannel = _channelListIndex();
                                  _pinnedEpg = _epgHighlightIndex();
                                  _groupStride = groupStride;
                                  _channelStride = channelStride;
                                  _epgStride = epgStride;
                                  final font = land ? 12.0 : 13.0;
                                  final logoW = (land ? 28.0 : 40.0) * ui;
                                  final logoH = (land ? 22.0 : 30.0) * ui;
                                  final numDigits = _channelNumDigitsFor(_channels);
                                  final numColW = _channelNumColWidth(font, digits: numDigits);
                                  final channelChrome = numColW + (land ? 4 : 12) * ui + logoW + (land ? 6 : 12) * ui;
                                  final channelFloor = channelChrome + 56 * ui;
                                  // 桌面全屏最多约占半屏，避免挡完画面；窄屏仍可到 92%
                                  final maxFrac = (_immersive && !land) ? 0.52 : 0.92;
                                  final contentW0 = groupW +
                                      gap1 +
                                      channelW +
                                      gapTab +
                                      epgTabW +
                                      (_epgOpen ? gap2 + epgW : 0);
                                  final leftW0 = contentW0 + padH;
                                  final panelW = leftW0.clamp(0.0, screenW * maxFrac);
                                  final innerMax = (panelW - padH).clamp(1.0, panelW);
                                  if (contentW0 > innerMax) {
                                    final fitted = _fitLivePanelCols(
                                      innerMax: innerMax,
                                      gap1: gap1,
                                      gapTab: gapTab,
                                      gap2: gap2,
                                      epgOpen: _epgOpen,
                                      channelFloor: channelFloor,
                                      groupFloor: (land ? 72.0 : 88.0) * ui,
                                      epgFloor: (land ? 120.0 : 140.0) * ui,
                                      epgTabFloor: (land ? 24.0 : 28.0) * ui,
                                      groupW: groupW,
                                      channelW: channelW,
                                      epgW: epgW,
                                      epgTabW: epgTabW,
                                    );
                                    groupW = fitted.groupW;
                                    channelW = fitted.channelW;
                                    epgW = fitted.epgW;
                                    epgTabW = fitted.epgTabW;
                                  }
                                  return SizedBox(
                                  width: panelW,
                                  child: ClipRect(
                                  child: Padding(
                                    padding: EdgeInsets.fromLTRB((land ? 6 : 8) * ui, (land ? 8 : 10) * ui, (land ? 6 : 8) * ui, (land ? 8 : 10) * ui),
                                    child: Row(
                                      children: [
                                        SizedBox(
                                          width: groupW,
                                          child: ListView.builder(
                                            controller: _groupScroll,
                                            itemCount: _groups.length,
                                            itemBuilder: (_, i) {
                                              final g = _groups[i];
                                              final locked = _groupLocked(i);
                                              return Padding(
                                                padding: EdgeInsets.only(bottom: (land ? 4 : 6) * ui),
                                                child: AppPill(
                                                  label: '${locked ? '🔒 ' : ''}${g['name'] ?? ''}',
                                                  height: pillH,
                                                  fontSize: font,
                                                  selected: i == _groupIdx,
                                                  marqueeWhenSelected: true,
                                                  onFocusChange: (focused) {
                                                    _groupFocusArm.onFocusChange('land:$i', focused, () {
                                                      if (!mounted || i == _groupIdx) return;
                                                      _cancelHideOverlays();
                                                      unawaited(_selectGroup(i, allowUnlock: false));
                                                    });
                                                  },
                                                  onTap: () {
                                                    _cancelHideOverlays();
                                                    unawaited(_selectGroup(i));
                                                  },
                                                ),
                                              );
                                            },
                                          ),
                                        ),
                                        SizedBox(width: gap1),
                                        SizedBox(
                                          width: channelW,
                                          child: ListView.builder(
                                            controller: _channelScroll,
                                            itemExtent: channelStride,
                                            itemCount: _channels.length,
                                            itemBuilder: (_, i) {
                                              final ch = _channels[i];
                                              final name = '${ch['name'] ?? ''}';
                                              final logo = '${ch['logo'] ?? ''}';
                                              final sel = _chIdx >= 0 && i == _chIdx;
                                              return Padding(
                                                padding: EdgeInsets.only(bottom: (land ? 2 : 4) * ui),
                                                child: TvFocus(
                                                  focusNode: _chFocus.of('ch:$i'),
                                                  borderRadius: 8 * ui,
                                                  onPressed: () => _selectChannelFromList(i),
                                                  onLongPress: () => unawaited(_toggleChannelFav(i)),
                                                  child: Material(
                                                    color: _liveChannelColor(p, sel: sel),
                                                    borderRadius: BorderRadius.circular(8 * ui),
                                                    child: SizedBox(
                                                      height: chH,
                                                      child: Padding(
                                                        padding: EdgeInsets.symmetric(horizontal: 6 * ui),
                                                        child: Row(
                                                          children: [
                                                            SizedBox(
                                                              width: numColW,
                                                              child: Text(
                                                                _channelNumberLabel(ch, i),
                                                                softWrap: false,
                                                                style: TextStyle(
                                                                  color: p.muted,
                                                                  fontSize: land ? 12 : 16,
                                                                  fontFeatures: const [FontFeature.tabularFigures()],
                                                                ),
                                                              ),
                                                            ),
                                                            SizedBox(width: (land ? 4 : 12) * ui),
                                                            _LiveChannelLogo(name: name, logo: logo, width: logoW, height: logoH),
                                                            SizedBox(width: (land ? 6 : 12) * ui),
                                                            Expanded(
                                                              child: _liveListTitle(
                                                                name,
                                                                selected: sel,
                                                                style: TextStyle(
                                                                  color: p.fg,
                                                                  fontSize: land ? 12 : 15,
                                                                  height: 1.15,
                                                                  fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                                                                ),
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              );
                                            },
                                          ),
                                        ),
                                        SizedBox(width: gapTab),
                                        SizedBox(
                                          width: epgTabW,
                                          child: TvFocus(
                                            focusNode: _epgTabFocus,
                                            borderRadius: 8,
                                            onPressed: () {
                                              _cancelHideOverlays();
                                              setState(() => _epgOpen = !_epgOpen);
                                              if (_epgOpen && _programs.isEmpty && _chIdx >= 0) {
                                                unawaited(_loadEpg());
                                              }
                                              if (_epgOpen) {
                                                _scheduleScrollEpgToHighlight();
                                                WidgetsBinding.instance.addPostFrameCallback((_) {
                                                  if (mounted && _epgOpen) _focusProgramList();
                                                });
                                              } else {
                                                WidgetsBinding.instance.addPostFrameCallback((_) {
                                                  if (mounted && _leftOpen) _focusChannelList();
                                                });
                                              }
                                            },
                                            child: Material(
                                              color: _epgOpen
                                                  ? p.selected.withOpacity(0.4)
                                                  : p.pillBg,
                                              borderRadius: BorderRadius.circular(8),
                                              child: Center(
                                                child: Text(
                                                  (_epgOpen ? '收起' : '节目单').split('').join('\n'),
                                                  textAlign: TextAlign.center,
                                                  style: TextStyle(
                                                    color: p.fg,
                                                    fontSize: land ? 11 : 12,
                                                    height: 1.25,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                        if (_epgOpen) ...[
                                        SizedBox(width: gap2),
                                        SizedBox(
                                          width: epgW,
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.stretch,
                                            children: [
                                              Padding(
                                                padding: EdgeInsets.only(bottom: (land ? 4 : 6) * ui, left: 2 * ui),
                                                child: Text(
                                                  'EPG',
                                                  style: TextStyle(
                                                    color: p.muted,
                                                    fontSize: land ? 11 : 13,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                              ),
                                              if (_epgDays.length > 1)
                                                _epgDayTabs(
                                                  land: land,
                                                  resetHideOnSelect: true,
                                                ),
                                              SizedBox(height: (land ? 4 : 6) * ui),
                                              Expanded(
                                                child: _programs.isEmpty
                                                    ? Center(
                                                        child: Text(
                                                          '暂无节目单',
                                                          style: TextStyle(color: p.muted, fontSize: land ? 11 : 13),
                                                        ),
                                                      )
                                                    : ListView.builder(
                                                        controller: _epgScroll,
                                                        itemCount: _programs.length,
                                                        itemBuilder: (_, i) => _epgProgramTile(
                                                          i,
                                                          land: land,
                                                        ),
                                                      ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  ),
                                );
                                }),
                              ),
                            ),
                          ),
                        if (_rightOpen && !KotvWinChrome.isNeeded)
                          Positioned(
                            right: 0,
                            top: 0,
                            bottom: 0,
                            child: MouseRegion(
                              onEnter: (_) {
                                _pointerInRightPanel = true;
                                _cancelHideOverlays();
                              },
                              onExit: (_) {
                                _pointerInRightPanel = false;
                                _scheduleHideOverlays();
                              },
                              child: Material(
                                color: KotvPalette.of(context).dialogBg,
                                child: Builder(builder: (context) {
                                  final p = KotvPalette.of(context);
                                  final land = KotvLayout.isLandscapeCompact(context);
                                  final ui = LayoutScale.grow(context);
                                  final rightW = land
                                      ? (c.maxWidth * 0.30).clamp(180.0, 240.0) * ui
                                      : 240.0 * ui;
                                  final pillH = land ? 30.0 : 40.0;
                                  return SizedBox(
                                  width: rightW,
                                  child: ListView(
                                    padding: EdgeInsets.all((land ? 8 : 14) * ui),
                                    children: [
                                      Text(
                                        '直播设置',
                                        style: TextStyle(
                                          color: p.fg,
                                          fontSize: land ? 14 : 18,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      SizedBox(height: (land ? 8 : 12) * ui),
                                      AppPill(
                                        label: '上一频道',
                                        height: pillH,
                                        fontSize: land ? 12 : 14,
                                        autofocus: true,
                                        focusNode: _rightFocus,
                                        onTap: () {
                                          final chs = _channels;
                                          if (chs.isEmpty) return;
                                          unawaited(_stepChannel(delta: _liveInvert ? 1 : -1));
                                        },
                                      ),
                                      SizedBox(height: 8 * ui),
                                      AppPill(
                                        label: '下一频道',
                                        height: 40,
                                        onTap: () {
                                          final chs = _channels;
                                          if (chs.isEmpty) return;
                                          unawaited(_stepChannel(delta: _liveInvert ? -1 : 1));
                                        },
                                      ),
                                      SizedBox(height: 8 * ui),
                                      AppPill(
                                        label: '换线路 (${_line + 1}/$_lines)',
                                        height: 40,
                                        onTap: () {
                                          if (_chIdx < 0 || _lines <= 1) return;
                                          _playChannel(_chIdx, line: (_line + 1) % _lines);
                                        },
                                      ),
                                      SizedBox(height: 8 * ui),
                                      AppPill(label: '刷新 EPG', height: 40, onTap: _loadEpg),
                                      SizedBox(height: 8 * ui),
                                      AppPill(label: '投屏', height: 40, onTap: () => unawaited(_cast())),
                                      SizedBox(height: 8 * ui),
                                      AppPill(
                                        label: '画面比例 · ${_liveScaleLabel(_liveScale)}',
                                        height: 40,
                                        onTap: () => unawaited(_cycleLiveScale()),
                                      ),
                                      SizedBox(height: 8 * ui),
                                      AppPill(
                                        label: '跨组换台 · ${_liveAcross ? '开' : '关'}',
                                        height: 40,
                                        onTap: _onLiveAcross,
                                      ),
                                      SizedBox(height: 8 * ui),
                                      AppPill(
                                        label: '反转换台 · ${_liveInvert ? '开' : '关'}',
                                        height: 40,
                                        onTap: _onLiveInvert,
                                      ),
                                      SizedBox(height: 8 * ui),
                                      AppPill(
                                        label: '失败换线 · ${_liveAutoChange ? '开' : '关'}',
                                        height: 40,
                                        onTap: _onLiveFailSwitch,
                                      ),
                                      SizedBox(height: 8 * ui),
                                      AppPill(label: '迷你桌面播放', height: 40, onTap: () => unawaited(_enterMini())),
                                      SizedBox(height: 8 * ui),
                                      AppPill(
                                        label: _immersive ? '退出全屏' : '全屏观看',
                                        height: 40,
                                        onTap: () => unawaited(_toggleLiveFullscreen()),
                                      ),
                                      SizedBox(height: 8 * ui),
                                      if (kotvCanSwitchPlayer(live: true)) ...[
                                        AppPill(
                                          label: '播放器 · ${flutterPlayerLabel(_playerVal)}',
                                          height: 40,
                                          onTap: () => unawaited(_pickPlayer()),
                                        ),
                                        SizedBox(height: 8 * ui),
                                      ],
                                      AppPill(
                                        label: '解码 · $_decodeLabel',
                                        height: 40,
                                        onTap: () => unawaited(_pickDecode()),
                                      ),
                                      if (_showDirectOutput) ...[
                                        SizedBox(height: 8 * ui),
                                        AppPill(
                                          label: '硬解直出 · ${_playback.directOutputActive ? '开' : '关'}',
                                          height: 40,
                                          onTap: () => unawaited(_toggleDirectOutput()),
                                        ),
                                      ],
                                      if (kotvPlayerRenderApplies(_playerVal)) ...[
                                        SizedBox(height: 8 * ui),
                                        AppPill(
                                          label: '渲染 · ${kotvPlayerRenderLabel(_renderMode)}',
                                          height: 40,
                                          onTap: () => unawaited(_pickRender()),
                                        ),
                                      ],
                                      SizedBox(height: 8 * ui),
                                      ListenableBuilder(
                                        listenable: _playback,
                                        builder: (context, _) {
                                          final vol = _playback.volume.clamp(1, 100).toDouble();
                                          return KotvStepSlider(
                                            label: '音量',
                                            value: vol,
                                            min: 1,
                                            max: 100,
                                            divisions: 99,
                                            format: (v) => '${v.round()}',
                                            padding: const EdgeInsets.only(top: 4),
                                            onChanging: (v) => unawaited(_playback.setVolume(v)),
                                            onCommit: (v) async {
                                              final n = v.round().clamp(1, 100);
                                              try {
                                                await _persistLiveSetting('playerVolume', '$n');
                                              } catch (_) {}
                                            },
                                          );
                                        },
                                      ),
                                      SizedBox(height: 8 * ui),
                                      AppPill(label: '打开设置页', height: 40, onTap: () => goKotvPage(ref, KotvPage.settings)),
                                      SizedBox(height: 16 * ui),
                                      Text('直播源', style: TextStyle(color: p.muted)),
                                      SizedBox(height: 8 * ui),
                                      for (var i = 0; i < _sources.length; i++)
                                        Padding(
                                          padding: EdgeInsets.only(bottom: 6 * ui),
                                          child: AppPill(
                                            // 仅一个源时换源位文案为「刷新」；再点当前源会 force 重拉频道表。
                                            label: _sources.length == 1
                                                ? '刷新'
                                                : '${_sources[i]['name'] ?? _sources[i]['url']}',
                                            suffix: _sources.length > 1 &&
                                                    (_sources[i]['current'] == true || i == _srcIdx)
                                                ? '（当前）'
                                                : null,
                                            height: 36,
                                            fontSize: 13,
                                            selected: i == _srcIdx,
                                            onTap: () => _loadSource(
                                              i,
                                              autoPlay: true,
                                              force: _sources.length == 1 || i == _srcIdx,
                                            ),
                                          ),
                                        ),
                                      SizedBox(height: 12 * ui),
                                        AppPill(
                                        label: '配置直播源',
                                        height: 40,
                                        onTap: () async {
                                          await showLivePicker(context, ref);
                                          await _bootstrap(forceLoad: true);
                                        },
                                      ),
                                      SizedBox(height: 8 * ui),
                                      AppPill(label: '关闭面板', height: 40, onTap: () => setState(() => _rightOpen = false)),
                                    ],
                                  ),
                                );
                                }),
                              ),
                            ),
                          ),
                        // 底栏信息条（频道名）；Win7 由原生 channel 条承接。
                        if (!KotvWinChrome.isNeeded &&
                            _channelInfoVisible &&
                            !_leftOpen &&
                            !_rightOpen &&
                            (!_catchup || !_catchupChrome))
                          Positioned(
                            left: 16,
                            right: 16,
                            bottom: 16,
                            child: Builder(builder: (context) {
                              final pal = KotvPalette.of(context);
                              return Material(
                                color: pal.dialogBg,
                                elevation: 0,
                                shadowColor: Colors.transparent,
                                surfaceTintColor: Colors.transparent,
                                borderRadius: BorderRadius.circular(10),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                  child: Row(
                                    children: [
                                      SizedBox(
                                        width: _channelNumColWidth(20, digits: _channelNum.length),
                                        child: Text(
                                          _channelNum,
                                          softWrap: false,
                                          overflow: TextOverflow.clip,
                                          style: TextStyle(
                                            color: pal.muted,
                                            fontSize: 20,
                                            fontFeatures: const [FontFeature.tabularFigures()],
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      _LiveChannelLogo(name: _title, logo: _currentLogo),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.stretch,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            KotvMarqueeText(
                                              _title,
                                              active: true,
                                              style: TextStyle(color: pal.fg, fontSize: 18, fontWeight: FontWeight.w600),
                                            ),
                                            if (_programTimeLabel.isNotEmpty ||
                                                _programTitleLabel.isNotEmpty ||
                                                _status.isNotEmpty)
                                              Row(
                                                children: [
                                                  if (_programTimeLabel.isNotEmpty) ...[
                                                    Text(
                                                      _programTimeLabel,
                                                      maxLines: 1,
                                                      softWrap: false,
                                                      style: TextStyle(
                                                        color: pal.muted,
                                                        fontSize: 12,
                                                        fontFeatures: const [FontFeature.tabularFigures()],
                                                      ),
                                                    ),
                                                    const SizedBox(width: 6),
                                                  ],
                                                  Expanded(
                                                    child: KotvMarqueeText(
                                                      [
                                                        if (_programTitleLabel.isNotEmpty) _programTitleLabel,
                                                        if (_programTitleLabel.isEmpty && _status.isNotEmpty) _status,
                                                      ].where((e) => e.isNotEmpty).join(' · '),
                                                      active: true,
                                                      style: TextStyle(color: pal.muted, fontSize: 13),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                          ],
                                        ),
                                      ),
                                      if (_lineLabel.isNotEmpty) ...[
                                        const SizedBox(width: 8),
                                        Flexible(
                                          child: KotvMarqueeText(
                                            _lineLabel,
                                            active: true,
                                            textAlign: TextAlign.right,
                                            style: TextStyle(color: pal.muted, fontSize: 13),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              );
                            }),
                          ),
                        // 底栏播控：仅回看。
                        if (_catchup && _catchupChrome && !_leftOpen && !_rightOpen)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: MouseRegion(
                              onEnter: (_) {
                                _pointerAtBottom = true;
                                _keepMouseVisible();
                                _catchupHideTimer?.cancel();
                                _cancelHideOverlays();
                              },
                              onExit: (_) {
                                _pointerAtBottom = false;
                                if (_catchup) {
                                  _pulseCatchupChrome();
                                } else {
                                  _scheduleHideOverlays();
                                }
                                _scheduleHideMouse();
                              },
                              child: _buildLiveCatchupChrome(
                                autofocusPlay: true,
                                offerFullscreen: false,
                                onBump: _bumpLiveChrome,
                                onMini: () => unawaited(_enterMini()),
                                onExpand: (_) => unawaited(_toggleLiveFullscreen()),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  /// 竖屏：顶栏 + 播放器(含控件) + 频道/EPG 切换。
  Widget _buildPortraitLive() {
    final p = KotvPalette.of(context);
    final chs = _channels;
    final title = _title.isNotEmpty ? _title : '直播';
    final showChrome = _catchup && (_portraitChrome || _catchupChrome);
    return Column(
      children: [
          LibraryTopBar(
            onBack: () {
              if (_handleLiveBack()) return;
              kotvPageBack(ref);
            },
            onSearch: () => goKotvPage(ref, KotvPage.search),
            onProfile: () => goKotvPage(ref, KotvPage.profile),
            onNews: () => showLatestNews(context, ref),
            title: title,
          ),
          AspectRatio(
          aspectRatio: 16 / 9,
          child: ColoredBox(
            key: _winLiveSurfaceKey,
            color: Colors.black,
            child: LayoutBuilder(
              builder: (context, c) {
                return MouseRegion(
                  cursor: _mouseCursor,
                  onHover: (e) => _onLivePointerMove(e, c, sides: false, portrait: true),
                  onExit: (_) => _onLivePointerExit(),
                  child: Stack(
              fit: StackFit.expand,
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _togglePortraitChrome,
                  onSecondaryTap: () => kotvHandleAppBack?.call(),
                  onDoubleTap: _onLiveDoubleTap,
                  child: _buildSharedLiveVideo(),
                ),
                // Android Hybrid：起播/换台无帧时盖黑防叠影；桌面 Texture 不挂此层。
                _buildLiveSurfaceCover(),
                _buildLiveDanmakuOverlay(),
                // Win7：转圈与网速由原生壳画（KotvWinBufferText）。
                if (!KotvWinChrome.isNeeded)
                  KotvBufferingOverlay(
                    player: _playback,
                    force: _status.contains('解析') ||
                        _status.contains('加载') ||
                        _status.contains('缓冲') ||
                        _loading,
                  ),
                if (_catchup && _playUrl.isNotEmpty)
                  CenterPlayPauseButton(
                    player: _playback,
                    hideWhenBuffering: true,
                    enabled: !_loading &&
                        !_status.contains('解析') &&
                        !_status.contains('加载') &&
                        !_status.contains('缓冲'),
                  ),
                if (_error != null)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
                    ),
                  ),
                if (showChrome)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: _buildLiveCatchupChrome(
                      autofocusPlay: true,
                      offerFullscreen: false,
                      onBump: _pulsePortraitChrome,
                      onMini: () => unawaited(_enterMini()),
                      onExpand: (_) => unawaited(_toggleLiveFullscreen()),
                    ),
                  ),
              ],
                  ),
                );
              },
            ),
          ),
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
          color: p.catBar,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  SizedBox(
                    width: _channelNumColWidth(15, digits: _channelNum.length),
                    child: Text(
                      _channelNum,
                      softWrap: false,
                      overflow: TextOverflow.clip,
                      style: TextStyle(
                        color: p.fg,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _LiveChannelLogo(name: title, logo: _currentLogo, width: 40, height: 30),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        KotvMarqueeText(
                          title,
                          active: true,
                          style: TextStyle(color: p.fg, fontSize: 15, fontWeight: FontWeight.w700),
                        ),
                        Row(
                          children: [
                            if (_programTimeLabel.isNotEmpty) ...[
                              Text(
                                _programTimeLabel,
                                maxLines: 1,
                                softWrap: false,
                                style: TextStyle(
                                  color: p.muted,
                                  fontSize: 12,
                                  fontFeatures: const [FontFeature.tabularFigures()],
                                ),
                              ),
                              const SizedBox(width: 6),
                            ],
                            Expanded(
                              child: KotvMarqueeText(
                                [
                                  if (_programTitleLabel.isNotEmpty) _programTitleLabel,
                                  if (_lineLabel.isNotEmpty) _lineLabel,
                                  if (_status.isNotEmpty) _status,
                                ].where((e) => e.isNotEmpty).join(' · '),
                                active: true,
                                style: TextStyle(color: p.muted, fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    AppPill(
                      label: '上一台',
                      height: 32,
                      fontSize: 12,
                      onTap: () {
                        if (chs.isEmpty) return;
                        _playChannel(_chIdx <= 0 ? chs.length - 1 : _chIdx - 1);
                      },
                    ),
                    const SizedBox(width: 6),
                    AppPill(
                      label: '下一台',
                      height: 32,
                      fontSize: 12,
                      onTap: () {
                        if (chs.isEmpty) return;
                        _playChannel((_chIdx + 1) % chs.length);
                      },
                    ),
                    const SizedBox(width: 6),
                    AppPill(
                      label: _lines > 1 ? '线路 ${_line + 1}/$_lines' : '线路',
                      height: 32,
                      fontSize: 12,
                      onTap: () {
                        if (_chIdx < 0 || _lines <= 1) return;
                        _playChannel(_chIdx, line: (_line + 1) % _lines);
                      },
                    ),
                    const SizedBox(width: 6),
                    AppPill(label: '刷新EPG', height: 32, fontSize: 12, onTap: _loadEpg),
                    const SizedBox(width: 6),
                    AppPill(label: '投屏', height: 32, fontSize: 12, onTap: () => unawaited(_cast())),
                    const SizedBox(width: 6),
                    AppPill(label: '全屏', height: 32, fontSize: 12, onTap: () => unawaited(_enterLiveFullscreen())),
                    const SizedBox(width: 6),
                    if (kotvCanSwitchPlayer(live: true)) ...[
                      AppPill(
                        label: flutterPlayerLabel(_playerVal),
                        height: 32,
                        fontSize: 12,
                        onTap: () => unawaited(_pickPlayer()),
                      ),
                      const SizedBox(width: 6),
                    ],
                    AppPill(
                      label: '解码·$_decodeLabel',
                      height: 32,
                      fontSize: 12,
                      onTap: () => unawaited(_pickDecode()),
                    ),
                    if (_showDirectOutput) ...[
                      const SizedBox(width: 6),
                      AppPill(
                        label: '直出·${_playback.directOutputActive ? '开' : '关'}',
                        height: 32,
                        fontSize: 12,
                        onTap: () => unawaited(_toggleDirectOutput()),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: AppPill(
                      label: '频道',
                      height: 34,
                      fontSize: 13,
                      selected: _portraitTab == 0,
                      onTap: () {
                        setState(() => _portraitTab = 0);
                        _scheduleScrollToCurrent(epg: false);
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: AppPill(
                      label: 'EPG节目单',
                      height: 34,
                      fontSize: 13,
                      selected: _portraitTab == 1,
                      onTap: () {
                        setState(() => _portraitTab = 1);
                        if (_programs.isEmpty && _chIdx >= 0) {
                          unawaited(_loadEpg());
                        } else {
                          _scheduleScrollEpgToHighlight();
                        }
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: _portraitTab == 0 ? _portraitChannelPanel(p, chs) : _portraitEpgPanel(p),
        ),
      ],
    );
  }

  Widget _portraitChannelPanel(KotvPalette p, List<Map<String, dynamic>> chs) {
    final groupLine = _oneLine(context, const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, height: 1.15));
    final groupBox = groupLine + 10 > 28 ? groupLine + 10 : 28.0;
    final groupStride = groupBox + 3;
    const channelStride = 39.0;
    final numDigits = _channelNumDigitsFor(chs);
    final numColW = _channelNumColWidth(11, digits: numDigits);
    _pinList(_groupScroll, _groupIdx, groupStride, _groupStride, _pinnedGroup);
    _pinList(_channelScroll, _channelListIndex(), channelStride, _channelStride, _pinnedChannel);
    _pinnedGroup = _groupIdx;
    _pinnedChannel = _channelListIndex();
    _groupStride = groupStride;
    _channelStride = channelStride;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 88,
          child: ColoredBox(
            color: p.bottomNav.withOpacity(0.92),
            child: ListView.builder(
              controller: _groupScroll,
              padding: const EdgeInsets.fromLTRB(4, 4, 3, 4),
              itemCount: _groups.length,
              itemBuilder: (_, i) {
                final g = _groups[i];
                final locked = _groupLocked(i);
                final name = '${locked ? '🔒' : ''}${g['name'] ?? ''}';
                final sel = i == _groupIdx;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: TvFocus(
                    borderRadius: 6,
                    onFocusChange: (focused) {
                      _groupFocusArm.onFocusChange('port:$i', focused, () {
                        if (!mounted || i == _groupIdx) return;
                        unawaited(_selectGroup(i, allowUnlock: false));
                      });
                    },
                    onPressed: () => unawaited(_selectGroup(i)),
                    child: Material(
                      color: sel ? p.selected : p.pillBg.withOpacity(0.7),
                      borderRadius: BorderRadius.circular(6),
                      child: Container(
                        width: double.infinity,
                        constraints: const BoxConstraints(minHeight: 28),
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
                        alignment: Alignment.center,
                        child: _liveListTitle(
                          name,
                          selected: sel,
                          align: TextAlign.center,
                          style: TextStyle(
                            color: sel ? Colors.white : p.fg,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            height: 1.15,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            controller: _channelScroll,
            padding: const EdgeInsets.fromLTRB(3, 4, 6, 4),
            itemExtent: channelStride,
            itemCount: chs.length,
            itemBuilder: (_, i) {
              final ch = chs[i];
              final name = '${ch['name'] ?? ''}';
              final logo = '${ch['logo'] ?? ''}';
              final sel = _chIdx >= 0 && i == _chIdx;
              return Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: TvFocus(
                  borderRadius: 6,
                  onPressed: () => _selectChannelFromList(i),
                  onLongPress: () => unawaited(_toggleChannelFav(i)),
                  child: Material(
                    color: _liveChannelColor(p, sel: sel),
                    borderRadius: BorderRadius.circular(6),
                    child: SizedBox(
                      height: 36,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Row(
                          children: [
                            SizedBox(
                              width: numColW,
                              child: Text(
                                _channelNumberLabel(ch, i),
                                softWrap: false,
                                style: TextStyle(
                                  color: p.muted,
                                  fontSize: 11,
                                  fontFeatures: const [FontFeature.tabularFigures()],
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            _LiveChannelLogo(name: name, logo: logo, width: 28, height: 22),
                            const SizedBox(width: 6),
                            Expanded(
                              child: _liveListTitle(
                                name,
                                selected: sel,
                                style: TextStyle(
                                  color: p.fg,
                                  fontSize: 12,
                                  fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _portraitEpgPanel(KotvPalette p) {
    final epgStride = _oneLine(context, const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)) + 24;
    final epgIndex = _epgHighlightIndex();
    _pinList(_epgScroll, epgIndex, epgStride, _epgStride, _pinnedEpg);
    _pinnedEpg = epgIndex;
    _epgStride = epgStride;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_epgDays.length > 1)
          _epgDayTabs(
            land: false,
            height: 40,
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
          ),
        Expanded(
          child: _programs.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('暂无节目单', style: TextStyle(color: p.muted, fontSize: 14)),
                      const SizedBox(height: 10),
                      AppPill(label: '刷新 EPG', height: 34, fontSize: 13, selected: true, onTap: _loadEpg),
                    ],
                  ),
                )
              : ListView.builder(
                  controller: _epgScroll,
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                  itemCount: _programs.length,
                  itemBuilder: (_, i) => _epgProgramTile(i, land: false, portrait: true),
                ),
        ),
      ],
    );
  }
}

class _LiveChannelLogo extends StatelessWidget {
  const _LiveChannelLogo({required this.name, required this.logo, this.width = 48, this.height = 36});

  final String name;
  final String logo;
  final double width;
  final double height;

  static const _palette = <Color>[
    Color(0xFFE53935),
    Color(0xFFD81B60),
    Color(0xFF8E24AA),
    Color(0xFF5E35B1),
    Color(0xFF3949AB),
    Color(0xFF1E88E5),
    Color(0xFF039BE5),
    Color(0xFF00ACC1),
    Color(0xFF00897B),
    Color(0xFF43A047),
    Color(0xFF7CB342),
    Color(0xFFC0CA33),
    Color(0xFFFB8C00),
    Color(0xFFF4511E),
    Color(0xFF6D4C41),
    Color(0xFF546E7A),
  ];

  Color get _bg {
    final letter = _letter;
    var h = 0;
    for (final r in letter.runes) {
      h = 31 * h + r;
    }
    if (h < 0) h = -h;
    return _palette[h % _palette.length];
  }

  String get _letter {
    var s = name.trimLeft();
    if (s.startsWith('★')) s = s.substring(1).trimLeft();
    if (s.isEmpty) return '！';
    return String.fromCharCode(s.runes.first);
  }

  bool get _httpLogo {
    final s = logo.trim();
    return s.startsWith('http://') || s.startsWith('https://') || s.startsWith('proxy://') || s.startsWith('data:');
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        width: width,
        height: height,
        child: _httpLogo
            ? KotvNetworkImage(
                logo.trim(),
                key: ValueKey(logo.trim()),
                fit: BoxFit.contain,
                gaplessPlayback: false,
                cacheWidth: width >= height
                    ? (width * MediaQuery.devicePixelRatioOf(context)).ceil().clamp(1, 512)
                    : null,
                cacheHeight: height > width
                    ? (height * MediaQuery.devicePixelRatioOf(context)).ceil().clamp(1, 512)
                    : null,
                errorBuilder: (_, __, ___) => _fallback(),
              )
            : _fallback(),
      ),
    );
  }

  Widget _fallback() {
    return ColoredBox(
      color: _bg,
      child: Center(
        child: Text(_letter, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
      ),
    );
  }
}
