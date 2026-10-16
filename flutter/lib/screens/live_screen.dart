import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import '../api/kotv_engine_url.dart';
import '../desktop/mini_player_window.dart';
import '../player/exo_playback.dart';
import '../player/fvp_playback.dart';
import '../player/html_playback.dart';
import '../player/art_playback.dart';
import '../player/xg_playback.dart';
import '../player/zw_playback.dart';
import '../player/fullscreen_mode.dart';
import '../player/kotv_platform.dart';
import '../player/kotv_playback.dart';
import '../player/video_eq.dart';
import '../player/kotv_player_factory.dart';
import '../player/media_kit_playback.dart';
import '../player/mpv_opts.dart';
import '../player/native_mpv_playback.dart';
import '../player/play_headers.dart';
import '../player/subtitle_style_util.dart';
import '../player/danmaku_layer.dart';
import '../player/playback_failover.dart';
import '../player/tv_remote_keys.dart';
import '../providers.dart';
import '../api/kotv_settings_cache.dart';
import '../remote/remote_bridge.dart';
import '../theme/kotv_palette.dart';
import '../theme/kotv_theme.dart';
import '../theme/stable_focus.dart';
import '../theme/layout_scale.dart';
import '../widgets/buffering_overlay.dart';
import '../widgets/cast_flow.dart';
import '../widgets/chrome.dart';
import '../widgets/h_scroll.dart';
import '../widgets/kotv_network_image.dart';
import '../widgets/kotv_step_slider.dart';
import '../widgets/kotv_tv_text_field.dart';
import '../widgets/dialogs.dart';
import '../widgets/live_player_chrome.dart';
import '../widgets/marquee_text.dart';
import '../widgets/mini_hover_shell.dart';
import '../widgets/vod_player_chrome.dart';
import 'detail_screen.dart';
import 'shell.dart';

const _liveKeepSep = '\$\$\$';
const _liveFavGroupName = '收藏';
/// 频道栏 / 信息条 / 控件自动隐藏（5s）。
const _liveOverlayHide = Duration(seconds: 5);
const _liveIdleStatus = '确定键打开频道列表 · 菜单键打开底栏 · 点击右侧换源/设置';
/// 回看快进快退步长（10s）。
const _liveCatchupSeekStep = Duration(seconds: 10);

class LiveScreen extends ConsumerStatefulWidget {
  const LiveScreen({super.key});

  /// 切 Tab：await 停掉直播页内全部后端，避免 FVP/HTML 卸树后后台出声。
  static Future<void> prepareLeave() => _LiveScreenState.prepareLeave();

  static bool get isImmersive => _LiveScreenState._active?._immersive == true;

  @override
  ConsumerState<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends ConsumerState<LiveScreen> with WidgetsBindingObserver {
  static _LiveScreenState? _active;

  static Completer<void>? _leaveDone;

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
      await active._releaseAllBackends().timeout(const Duration(seconds: 4));
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

  /// 直播切台：FVP 只 pause，其它后端走换集停播。
  Future<void> _stopPlaybackForLiveZap() async {
    final p = _playback;
    if (p is FvpPlayback) {
      await p.pauseForLiveZap();
      return;
    }
    await p.stopForEpisodeSwitch();
  }

  KotvPlayback _ensureMpv() {
    if (kotvIsAndroid()) {
      _mk ??= NativeMpvPlayback(opts: _mpvOpts.copyWith(decodeMode: _decodeMode));
      return _mk!;
    }
    // 直播 Player 必须 live 创建/初始化，否则 _prepareOpts 会先写入点播 demuxer（回归 980a0e3）。
    _mkPlayer ??= kotvCreateMpvPlayer(live: true, conf: _mpvOpts.conf);
    _mk ??= MediaKitPlayback(
      _mkPlayer!,
      opts: _mpvOpts.copyWith(decodeMode: _decodeMode),
      live: true,
    );
    return _mk!;
  }

  /// 切到其它内置后端时停掉闲置引擎。
  /// 调用方须在改 [_playerVal] **之前**调用，以便旧 FVP/Surface 仍在树上时完成 release。
  /// 先 pause 再 stop/release；离开 MPV 时桌面也要 dispose Player，避免双引擎抢 AO。
  Future<void> _stopInactiveBackends(KotvEmbedBackend keep) async {
    if (keep != KotvEmbedBackend.mpv) {
      try {
        await _mk?.pause();
      } catch (_) {}
      try {
        await _mk?.stop();
      } catch (_) {}
      final mkPlayer = _mkPlayer;
      _mkPlayer = null;
      try {
        _mk?.dispose();
      } catch (_) {}
      _mk = null;
      await kotvDisposeMpvPlayer(mkPlayer);
    }
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
  bool _liveAcross = true;
  bool _liveInvert = false;
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
  RemoteBridge? _boundRemote;
  KotvPlayback? _errorWiredPb;
  VoidCallback? _playbackErrorListener;
  StreamSubscription<bool>? _endedSub;
  bool _failSwitchBusy = false;
  bool _endedBusy = false;
  bool _pickingPlayer = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
    WidgetsBinding.instance.addPostFrameCallback((_) => _attachRemoteHandlers());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      if (_playerBackground == 'off' && _playback.playing) {
        unawaited(_playback.pause());
      } else if (_playerBackground == 'audio' && _playUrl.isNotEmpty) {
        unawaited(_playback.setVideoOutputEnabled(false));
      }
    } else if (state == AppLifecycleState.resumed) {
      if (_playerBackground == 'audio' && _playUrl.isNotEmpty) {
        unawaited(_playback.setVideoOutputEnabled(true));
      }
    }
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
    _detachRemoteHandlers();
    if (_active == this) _active = null;
    kotvUnregisterQuitHook(_prepareQuit);
    liveScreenHandleBack = null;
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
    _unwireLivePlaybackErrors();
    _unwireLivePlaybackEnded();
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

  void _onRemoteLiveDanmaku(String text) {
    if (!mounted || text.trim().isEmpty) return;
    final sec = _playback.position.inMilliseconds / 1000.0;
    final next = List<DanmakuItem>.of(_danmakuItems.value)
      ..add(DanmakuItem(time: sec, content: text.trim()));
    _danmakuItems.value = next;
  }

  Widget _buildLiveDanmakuOverlay() {
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
    if (!mounted || path.trim().isEmpty) return;
    final name = path.split(RegExp(r'[/\\]')).last;
    unawaited(_playback.addSubtitleFile(path.trim(), title: name));
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
        settings = Map<String, dynamic>.from((st['settings'] as Map?) ?? const {});
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
    final liveChange = '${settings['liveChange'] ?? settings['liveAutoChange'] ?? 'true'}'.trim().toLowerCase();
    _liveAutoChange = liveChange != 'false' && liveChange != 'off' && liveChange != '0';
    final across = '${settings['liveAcross'] ?? 'true'}'.trim().toLowerCase();
    _liveAcross = across != 'false' && across != 'off' && across != '0';
    final invert = '${settings['liveInvert'] ?? 'false'}'.trim().toLowerCase();
    _liveInvert = invert == 'true' || invert == '1' || invert == 'on';
    final scaleLive = '${settings['playerScaleLive'] ?? settings['playerScale'] ?? 'default'}'.trim();
    _liveScale = scaleLive.isEmpty ? 'default' : scaleLive;
    _liveAspect = _liveAspectFromScale(_liveScale);
    final bg = '${settings['playerBackground'] ?? 'pip'}'.trim().toLowerCase();
    _playerBackground = (bg == 'off' || bg == 'audio' || bg == 'pip') ? bg : 'pip';
    kotvApplyPlayUaSetting('${settings['ua'] ?? ''}');
  }

  /// 列表已出后：把解码/渲染/字幕/音量落到当前引擎。
  Future<void> _applyLiveBootstrapPlayback(Map<String, dynamic> settings) async {
    if (settings.isEmpty) return;
    try {
      final mk = _mk;
      if (mk is NativeMpvPlayback) {
        unawaited(mk.applyOpts(_mpvOpts.copyWith(decodeMode: _decodeMode)));
      } else if (mk is MediaKitPlayback) {
        unawaited(mk.applyOpts(_mpvOpts.copyWith(decodeMode: _decodeMode)));
      }
      _exo?.applyPlayerOptions(settings);
      _fvp?.applyPlayerOptions(settings);
      final fontScale = (double.tryParse('${settings['subtitleFontScale'] ?? '1.0'}') ?? 1.0).clamp(0.5, 2.0);
      final subPos = kotvSubtitlePosFromSettings(settings['subtitlePos']);
      final subSecPos = double.tryParse('${settings['subtitleSecondaryPos'] ?? '10'}') ?? 10.0;
      final styleMode = '${settings['subtitleStyleMode'] ?? 'original'}'.trim().toLowerCase();
      final forceStyle = styleMode == 'custom';
      final useSystem = styleMode == 'system';
      final subColor = '${settings['subtitleColor'] ?? '#FFFFFF'}'.trim();
      final subBorder = '${settings['subtitleBorderColor'] ?? '#000000'}'.trim();
      final subBorderSize = double.tryParse('${settings['subtitleBorderSize'] ?? '2'}') ?? 2.0;
      final subBg = '${settings['subtitleBgColor'] ?? '#00000000'}'.trim();
      final edgeType = '${settings['subtitleEdgeType'] ?? 'outline'}'.trim().toLowerCase();
      final double textOp = (double.tryParse('${settings['subtitleTextOpacity'] ?? '100'}') ?? 100.0).clamp(0.0, 100.0);
      final double bgOp = (double.tryParse('${settings['subtitleBgOpacity'] ?? '100'}') ?? 100.0).clamp(0.0, 100.0);
      final double edgeOp = (double.tryParse('${settings['subtitleEdgeOpacity'] ?? '100'}') ?? 100.0).clamp(0.0, 100.0);
      final subOffset = int.tryParse('${settings['subtitleOffsetMs'] ?? '0'}') ?? 0;
      final shadowStrength = kotvSubtitleShadowStrength('${settings['subtitleShadowStrength'] ?? '50'}');
      final subFont = kotvNormalizeSubtitleFont('${settings['subtitleFont'] ?? 'default'}');
      final subFontPath = '${settings['subtitleFontPath'] ?? ''}'.trim();
      unawaited(_playback.setSubtitleStyle(
        scale: fontScale.toDouble(),
        pos: subPos.clamp(-20, 30).toDouble(),
        secondaryPos: subSecPos.clamp(0, 150).toDouble(),
        color: forceStyle && subColor.isNotEmpty ? subColor : null,
        borderColor: forceStyle && subBorder.isNotEmpty ? subBorder : null,
        borderSize: forceStyle ? subBorderSize.clamp(0, 8).toDouble() : null,
        bgColor: forceStyle && subBg.isNotEmpty ? subBg : null,
        edgeType: forceStyle ? edgeType : null,
        useSystemStyle: useSystem,
        textOpacity: forceStyle || useSystem ? textOp : null,
        bgOpacity: forceStyle || useSystem ? bgOp : null,
        edgeOpacity: forceStyle || useSystem ? edgeOp : null,
        shadowStrength: forceStyle || useSystem ? shadowStrength : null,
        font: forceStyle || useSystem ? subFont : null,
        fontPath: forceStyle || useSystem ? (subFontPath.isEmpty ? null : subFontPath) : null,
        forceStyle: forceStyle,
      ));
      unawaited(_playback.setSubtitleOffsetMs(subOffset.clamp(-300000, 300000)));
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

  /// UI 分组/频道 → 引擎真实下标（收藏组映射回源内位置）。
  ({int group, int channel})? _engineChannelRef(int uiGroup, int uiChannel) {
    if (uiGroup < 0 || uiGroup >= _groups.length) return null;
    final g = _groups[uiGroup];
    final chs = ((g['channels'] as List?) ?? []).whereType<Map>().toList();
    if (uiChannel < 0 || uiChannel >= chs.length) return null;
    if (g['_kotvFav'] != true) {
      final engGroup = _hasInjectedFavGroup ? uiGroup - 1 : uiGroup;
      if (engGroup < 0) return null;
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
          final engGroup = _hasInjectedFavGroup ? i - 1 : i;
          if (engGroup < 0) continue;
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
    // 单槽 cached_m3u8 换台即失效，写回会导致同台再直开 404。
    if (_isEphemeralLivePlayUrl(url) || _isEphemeralLivePlayUrl(direct)) {
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

  bool _isEphemeralLivePlayUrl(String url) {
    final u = url.toLowerCase();
    return u.contains('/proxy/cached_m3u8') || u.contains('/proxy/rolling_m3u8');
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
      await ref.read(apiProvider).liveUnlock(group: groupIdx, password: ctrl.text.trim());
      setState(() => _unlocked.add(groupIdx));
      ctrl.dispose();
      return true;
    } catch (e) {
      ctrl.dispose();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
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

  Future<void> _selectGroup(int i) async {
    if (!await _ensureUnlocked(i)) return;
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
  }) async {
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
      _liveAspect = _liveAspectFromScale(_liveScale);
      _exo?.applyPlayerOptions(playSettings);
      _fvp?.applyPlayerOptions(playSettings);
    }
    final renderMode = kotvNormalizePlayerRender(_renderMode);
    final hasDrm = drm != null && '${drm['type'] ?? ''}'.trim().isNotEmpty;
    final startPlayer = (hasDrm && kotvIsAndroid()) ? 'innie#exo' : _prefPlayerVal;
    final failover = KotvPlaybackFailover(
      playerVal: startPlayer,
      decodeMode: _prefDecodeMode,
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
      final mediaHint = directUrl.trim().isNotEmpty ? directUrl : url;
      final hdrMap = kotvNormalizePlayHeaders(headers, url: mediaHint);
      final resolved = kotvResolvePlayOpenTarget(
        playUrl: url,
        directUrl: directUrl,
        headers: hdrMap,
        magnet: false,
        sendHeaders: kotvPlaybackSendsHeaders(
          playerVal: failover.playerVal,
          mediaUrl: mediaHint,
          headers: hdrMap,
        ),
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
          await _dropStalePlayback(pb);
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
        if (!failover.enabled) return;
      } catch (e) {
        lastError = e;
        if (!failover.enabled) rethrow;
      }
      if (stale()) {
        await _dropStalePlayback(pb);
        return;
      }
      final step = failover.nextStep();
      if (step == null) break;
      try {
        await pb.release();
      } catch (_) {
        try {
          await pb.stop();
        } catch (_) {}
      }
      await _stopInactiveBackends(kotvEmbedBackend(step.playerVal));
      if (stale()) return;
      setState(() {
        _playerVal = step.playerVal;
        _decodeMode = step.decodeMode;
        _status = step.status;
      });
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
      await pb.awaitReadyAfterOpen();
    } on KotvSilentVideoException {
      if (stale() || !failover.enabled) return;
      final step = failover.nextStep();
      if (step == null) return;
      try {
        await pb.release();
      } catch (_) {
        try {
          await pb.stop();
        } catch (_) {}
      }
      if (stale()) return;
      setState(() {
        _playerVal = step.playerVal;
        _decodeMode = step.decodeMode;
        _prefPlayerVal = step.playerVal;
        _prefDecodeMode = step.decodeMode;
        _status = step.status;
      });
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
        );
      } catch (_) {}
    } catch (_) {}
  }

  /// 起播途中已作废：实例仍归本页（换台）交给新一次起播；
  /// 已被 [_releaseAllBackends] / dispose 摘掉并释放（离开直播）则再停一次，防止打开晚到后出声。
  Future<void> _dropStalePlayback(KotvPlayback pb) async {
    final owned = identical(pb, _mk) ||
        identical(pb, _fvp) ||
        identical(pb, _exo) ||
        identical(pb, _html) ||
        identical(pb, _art) ||
        identical(pb, _xg) ||
        identical(pb, _zw);
    if (owned) return;
    try {
      await pb.pause();
    } catch (_) {}
    try {
      await pb.stop();
    } catch (_) {}
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

  /// 全屏/竖屏/横屏共用画面。Android PlatformView 才用 GlobalKey reparent。
  Widget _buildSharedLiveVideo() {
    final inner = _liveVideoInner();
    if (kotvIsAndroid() && _mk is NativeMpvPlayback) {
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
    final mpvNativeScale = kotvIsAndroid() && _mk is NativeMpvPlayback;
    if (!mpvNativeScale && ratio != null && ratio > 0) {
      view = ColoredBox(
        color: Colors.black,
        child: Center(child: AspectRatio(aspectRatio: ratio, child: view)),
      );
    }
    return ExcludeFocus(child: view);
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
        final noFrame = _playback.width <= 0 && _playback.height <= 0;
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

  AspectSpec _liveAspectFromScale(String scale) {
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
      _liveAspect = _liveAspectFromScale(next);
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
      // isChange 且非末线路 → nextLine。
      final curLine = _line;
      if (_liveAutoChange && _lines > 1 && curLine < _lines - 1) {
        final next = curLine + 1;
        setState(() => _status = '线路失败，自动换线 ${next + 1}/$_lines…');
        await _playChannel(chIdx, line: next);
        return;
      }
      setState(() => _status = '播放失败: $e');
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
    if (_playUrl.isEmpty) {
      if (mounted) showAppNews(context, '请先播放内容再投屏');
      return;
    }
    final msg = await runKotvCast(
      context,
      ref.read(apiProvider),
      positionMs: _playback.position.inMilliseconds,
      onStatus: (m) {
        if (mounted) setState(() => _status = m);
      },
    );
    if (msg != null && mounted) {
      setState(() => _status = msg);
      if (msg.startsWith('已投屏到')) {
        unawaited(_playback.pause());
      }
    }
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
        setState(() {
          _miniDesktop = inPip;
          if (_catchup) _catchupChrome = inPip;
        });
      };
      final ok = await _playback.enterPictureInPicture();
      if (!mounted) return;
      if (ok) {
        setState(() {
          _miniDesktop = true;
          _leftOpen = false;
          _rightOpen = false;
          if (_catchup) _catchupChrome = true;
        });
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
      setState(() {
        _miniDesktop = inPip;
        if (_catchup) _catchupChrome = inPip;
      });
    };
    await MiniPlayerWindow.enter();
    if (!mounted) return;
    if (MiniPlayerWindow.active) {
      setState(() {
        _miniDesktop = true;
        _leftOpen = false;
        _rightOpen = false;
        if (_catchup) _catchupChrome = true;
      });
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
    // 先落沉浸布局（Texture 几何），再系统全屏；Windows 上 setFullScreen 会重建 HWND。
    setState(() {
      _desktopFs = desktopFs;
      _immersive = true;
      _leftOpen = false;
      _rightOpen = false;
      _chromeVisible = false;
    });
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    await kotvEnterSystemFullscreen(desktopFs);
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
    }
    await kotvExitSystemFullscreen(
      wasDisplayFullscreen: _desktopFs == KotvDesktopFullscreenKind.display,
    );
    if (!mounted) return;
    // 竖屏列表重建后直接停在当前分组、频道和节目。
    _scheduleScrollToCurrent();
  }

  Future<void> _pickDecode() async {
    final v = await pickChoice(context, title: '解码方式', current: _decodeMode, options: const [
      ('自动', 'auto'),
      ('软解码', 'soft'),
      ('硬解码', 'hard'),
    ]);
    if (v == null) return;
    setState(() {
      _decodeMode = v;
      _prefDecodeMode = v;
    });
    await _playback.setDecodeMode(v);
    try {
      await _persistLiveSetting('playerDecode', v);
    } catch (_) {}
    if (_playUrl.isNotEmpty) {
      final pos = _playback.position;
      // 直播/回看均 live 起播；进度经 startAt 在首次 play 前恢复。
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
  }

  Future<void> _pickRender() async {
    final v = await pickChoice(context, title: '渲染方式', current: _renderMode, options: const [
      ('Surface（推荐，HDR）', 'surface'),
      ('Texture', 'texture'),
    ]);
    if (v == null) return;
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
      final options = kotvLivePlayerOptions();
      final v = await pickChoice(navCtx, title: '直播播放器', current: _prefPlayerVal, options: options);
      if (v == null || !mounted) return;
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
      if (v.startsWith('outie#') && _playUrl.isNotEmpty) {
        try {
          await ref.read(apiProvider).playerExternal(url: _playUrl, player: v);
          await _playback.pause();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已用${flutterPlayerLabel(v)}打开')));
          }
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
    } finally {
      _pickingPlayer = false;
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
    _hideTimer?.cancel();
    _hideTimer = Timer(_liveOverlayHide, () {
      if (mounted) {
        setState(() {
          _leftOpen = false;
          _rightOpen = false;
          _epgOpen = false;
          _chromeVisible = false;
          _channelInfoVisible = false;
        });
      }
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
      return;
    }
    _openLeft();
  }

  void _toggleRight() {
    if (_rightOpen) {
      setState(() => _rightOpen = false);
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
    return (fontSize * 0.62 * digits.clamp(3, 8) + 10).clamp(40.0, 120.0);
  }

  /// 未选中用省略号。选中才跑马灯，避免频道列表每一行都挂动画。
  Widget _liveListTitle(String text, {required bool selected, required TextStyle style, TextAlign align = TextAlign.left}) {
    if (!selected) {
      return Text(
        text,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
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
      _scheduleHideOverlays();
      if (_programs.isEmpty) {
        unawaited(_loadEpg());
      } else {
        _scheduleScrollEpgToHighlight();
      }
      return;
    }
    unawaited(_playChannel(i));
  }

  /// 点中间：关菜单，或像抖音一样点画面播/停（左右仍是频道/设置）。
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

  void _onHover(PointerHoverEvent e, BoxConstraints c) {
    const hot = 16.0;
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
    _scheduleHideMouse();
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
    required double wScale,
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
              color: sel
                  ? p.selected.withOpacity(playing ? 0.95 : 0.75)
                  : p.pillBg.withOpacity(0.7),
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
    return Padding(
      padding: EdgeInsets.only(bottom: land ? 2 : 4),
      child: TvFocus(
        focusNode: _progFocus.of('p:$i'),
        borderRadius: 6,
        onPressed: canCatchup ? activate : null,
        child: Material(
            color: sel
                ? p.selected.withOpacity(playing ? 0.95 : 0.75)
                : p.pillBg.withOpacity(0.7),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: land ? 6 : 8,
                vertical: land ? 5 : 8,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (start.isNotEmpty)
                    SizedBox(
                      width: land ? 38 : 44,
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
                        fontSize: land ? 12 : (12.0 * wScale.clamp(1.0, 1.2)),
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
    if (_catchup) {
      _pulseCatchupChrome();
    } else {
      _bumpLiveChrome();
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
          kotvIsUpKey(key) ||
          kotvIsDownKey(key) ||
          kotvIsLeftKey(key) ||
          kotvIsRightKey(key)) {
        if (!isDown) return KeyEventResult.ignored;
        final primary = FocusManager.instance.primaryFocus;
        if ((kotvIsEnterKey(key) || kotvIsMediaPlayPause(key)) &&
            (primary == null || primary == node) &&
            !_leftOpen &&
            !_rightOpen) {
          _showLiveChromeAndFocusPlay();
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
    if (!_loading && _sources.isEmpty && _error == null) {
      return Column(
        children: [
          LibraryTopBar(
            onBack: () => kotvPageBack(ref),
            onSearch: () => goKotvPage(ref, KotvPage.search),
            onProfile: () => goKotvPage(ref, KotvPage.profile),
            onNews: () => showAppNews(context, remoteHint(ref)),
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

    // 竖屏 / 窄窗：上播放器 + 下频道列表（移动端布局）。沉浸全屏则走下方 PC 同款左右菜单。
    if (!_immersive && (KotvLayout.useBottomNav(context) || KotvLayout.isCompact(context))) {
      return _buildPortraitLive();
    }

    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: ColoredBox(
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
                  _buildSharedLiveVideo(),
                  // Android Hybrid：起播/换台无帧时盖黑防叠影；桌面 Texture 不挂此层。
                  _buildLiveSurfaceCover(),
                  _buildLiveDanmakuOverlay(),
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
                  // 点击分区：左 28% 频道 / 右 28% 设置 / 中 点画面播停（抖音式）
                  Positioned.fill(
                    child: Row(
                      children: [
                        Expanded(
                          flex: 28,
                          child: GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onTap: _toggleLeft,
                            onSecondaryTap: () => kotvHandleAppBack?.call(),
                            onDoubleTap: _onLiveDoubleTap,
                          ),
                        ),
                        Expanded(
                          flex: 44,
                          child: GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onTap: _onCenterTap,
                            onSecondaryTap: () => kotvHandleAppBack?.call(),
                            onDoubleTap: _onLiveDoubleTap,
                          ),
                        ),
                        Expanded(
                          flex: 28,
                          child: GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onTap: _toggleRight,
                            onSecondaryTap: () => kotvHandleAppBack?.call(),
                            onDoubleTap: _onLiveDoubleTap,
                          ),
                        ),
                      ],
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
                  if (_leftOpen)
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      child: MouseRegion(
                        onEnter: (_) => _cancelHideOverlays(),
                        onExit: (_) => _scheduleHideOverlays(),
                        child: Material(
                          color: KotvPalette.of(context).dialogBg,
                          child: Builder(builder: (context) {
                            final p = KotvPalette.of(context);
                            final screenW = c.maxWidth;
                            final land = KotvLayout.isLandscapeCompact(context);
                            // 列宽按屏宽缩放：写死 120/240/220 在 1080P 全屏仍偏窄，中文台名/EPG 会被 ellipsis 裁掉。
                            final wScale = land
                                ? 1.0
                                : (screenW / LayoutScale.designW).clamp(1.0, 1.55);
                            var groupW = (land ? 112.0 : 136.0) * wScale;
                            var channelW = (land ? 248.0 : 280.0) * wScale;
                            var epgW = (land ? 200.0 : 260.0) * wScale;
                            var epgTabW = land ? 28.0 : 32.0;
                            final padH = (land ? 6.0 : 8.0) * 2;
                            final gap1 = land ? 4.0 : 6.0;
                            final gapTab = land ? 4.0 : 6.0;
                            final gap2 = land ? 6.0 : 6.0;
                            final pillH = land ? 30.0 : 36.0;
                            final chH = land ? 36.0 : 48.0;
                            final groupStride = pillH * LayoutScale.layoutOf(context) + (land ? 4.0 : 6.0);
                            final channelStride = chH + (land ? 2.0 : 4.0);
                            final epgFont = land ? 12.0 : (12.0 * wScale.clamp(1.0, 1.2));
                            final epgStride = _oneLine(
                                  context,
                                  TextStyle(fontSize: epgFont, height: 1.2, fontWeight: FontWeight.w700),
                                ) +
                                (land ? 10.0 : 16.0) +
                                (land ? 2.0 : 4.0);
                            _pinList(_groupScroll, _groupIdx, groupStride, _groupStride, _pinnedGroup);
                            _pinList(_channelScroll, _channelListIndex(), channelStride, _channelStride, _pinnedChannel);
                            _pinList(_epgScroll, _epgHighlightIndex(), epgStride, _epgStride, _pinnedEpg);
                            _pinnedGroup = _groupIdx;
                            _pinnedChannel = _channelListIndex();
                            _pinnedEpg = _epgHighlightIndex();
                            _groupStride = groupStride;
                            _channelStride = channelStride;
                            _epgStride = epgStride;
                            final font = land ? 12.0 : (13.0 * wScale.clamp(1.0, 1.25));
                            final logoW = land ? 28.0 : 40.0;
                            final logoH = land ? 22.0 : 30.0;
                            final numDigits = _channelNumDigitsFor(_channels);
                            final numColW = _channelNumColWidth(font, digits: numDigits);
                            final channelChrome = numColW + (land ? 4 : 12) + logoW + (land ? 6 : 12);
                            final channelFloor = channelChrome + 56;
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
                                groupFloor: land ? 72.0 : 88.0,
                                epgFloor: land ? 120.0 : 140.0,
                                epgTabFloor: land ? 24.0 : 28.0,
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
                              padding: EdgeInsets.fromLTRB(land ? 6 : 8, land ? 8 : 10, land ? 6 : 8, land ? 8 : 10),
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
                                          padding: EdgeInsets.only(bottom: land ? 4 : 6),
                                          child: AppPill(
                                            label: '${locked ? '🔒 ' : ''}${g['name'] ?? ''}',
                                            height: pillH,
                                            fontSize: font,
                                            selected: i == _groupIdx,
                                            marqueeWhenSelected: true,
                                            onTap: () {
                                              _cancelHideOverlays();
                                              _selectGroup(i);
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
                                          padding: EdgeInsets.only(bottom: land ? 2 : 4),
                                          child: TvFocus(
                                            focusNode: _chFocus.of('ch:$i'),
                                            borderRadius: 8,
                                            onPressed: () => _selectChannelFromList(i),
                                            onLongPress: () => unawaited(_toggleChannelFav(i)),
                                            child: Material(
                                              color: sel
                                                  ? p.selected.withOpacity(0.28)
                                                  : p.pillBg.withOpacity(0.55),
                                              borderRadius: BorderRadius.circular(8),
                                              child: SizedBox(
                                                height: chH,
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
                                                            fontSize: land ? 12 : 16,
                                                            fontFeatures: const [FontFeature.tabularFigures()],
                                                          ),
                                                        ),
                                                      ),
                                                      SizedBox(width: land ? 4 : 12),
                                                      _LiveChannelLogo(name: name, logo: logo, width: logoW, height: logoH),
                                                      SizedBox(width: land ? 6 : 12),
                                                      Expanded(
                                                        child: _liveListTitle(
                                                          name,
                                                          selected: sel,
                                                          style: TextStyle(
                                                            color: p.fg,
                                                            fontSize: land ? 12 : (15.0 * wScale.clamp(1.0, 1.2)),
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
                                          padding: EdgeInsets.only(bottom: land ? 4 : 6, left: 2),
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
                                        SizedBox(height: land ? 4 : 6),
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
                                                    wScale: wScale,
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
                  if (_rightOpen)
                    Positioned(
                      right: 0,
                      top: 0,
                      bottom: 0,
                      child: MouseRegion(
                        onEnter: (_) => _cancelHideOverlays(),
                        onExit: (_) => _scheduleHideOverlays(),
                        child: Material(
                          color: KotvPalette.of(context).dialogBg,
                          child: Builder(builder: (context) {
                            final p = KotvPalette.of(context);
                            final land = KotvLayout.isLandscapeCompact(context);
                            final wScale = land
                                ? 1.0
                                : (c.maxWidth / LayoutScale.designW).clamp(1.0, 1.55);
                            final rightW = land
                                ? (c.maxWidth * 0.30).clamp(180.0, 240.0)
                                : (240.0 * wScale).clamp(220.0, 360.0);
                            final pillH = land ? 30.0 : 40.0;
                            return SizedBox(
                            width: rightW,
                            child: ListView(
                              padding: EdgeInsets.all(land ? 8 : 14),
                              children: [
                                Text(
                                  '直播设置',
                                  style: TextStyle(
                                    color: p.fg,
                                    fontSize: land ? 14 : 18,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                SizedBox(height: land ? 8 : 12),
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
                                const SizedBox(height: 8),
                                AppPill(
                                  label: '下一频道',
                                  height: 40,
                                  onTap: () {
                                    final chs = _channels;
                                    if (chs.isEmpty) return;
                                    unawaited(_stepChannel(delta: _liveInvert ? -1 : 1));
                                  },
                                ),
                                const SizedBox(height: 8),
                                AppPill(
                                  label: '换线路 (${_line + 1}/$_lines)',
                                  height: 40,
                                  onTap: () {
                                    if (_chIdx < 0 || _lines <= 1) return;
                                    _playChannel(_chIdx, line: (_line + 1) % _lines);
                                  },
                                ),
                                const SizedBox(height: 8),
                                AppPill(label: '刷新 EPG', height: 40, onTap: _loadEpg),
                                const SizedBox(height: 8),
                                AppPill(label: '投屏', height: 40, onTap: () => unawaited(_cast())),
                                const SizedBox(height: 8),
                                AppPill(
                                  label: '画面比例 · ${_liveScaleLabel(_liveScale)}',
                                  height: 40,
                                  onTap: () => unawaited(_cycleLiveScale()),
                                ),
                                const SizedBox(height: 8),
                                AppPill(
                                  label: '跨组换台 · ${_liveAcross ? '开' : '关'}',
                                  height: 40,
                                  onTap: _onLiveAcross,
                                ),
                                const SizedBox(height: 8),
                                AppPill(
                                  label: '反转换台 · ${_liveInvert ? '开' : '关'}',
                                  height: 40,
                                  onTap: _onLiveInvert,
                                ),
                                const SizedBox(height: 8),
                                AppPill(
                                  label: '失败换线 · ${_liveAutoChange ? '开' : '关'}',
                                  height: 40,
                                  onTap: _onLiveFailSwitch,
                                ),
                                const SizedBox(height: 8),
                                AppPill(label: '迷你桌面播放', height: 40, onTap: () => unawaited(_enterMini())),
                                const SizedBox(height: 8),
                                AppPill(
                                  label: _immersive ? '退出全屏' : '全屏观看',
                                  height: 40,
                                  onTap: () => unawaited(_toggleLiveFullscreen()),
                                ),
                                const SizedBox(height: 8),
                                if (kotvCanSwitchPlayer(live: true)) ...[
                                  AppPill(
                                    label: '播放器 · ${flutterPlayerLabel(_playerVal)}',
                                    height: 40,
                                    onTap: () => unawaited(_pickPlayer()),
                                  ),
                                  const SizedBox(height: 8),
                                ],
                                AppPill(
                                  label: '解码 · $_decodeLabel',
                                  height: 40,
                                  onTap: () => unawaited(_pickDecode()),
                                ),
                                if (kotvPlayerRenderApplies(_playerVal)) ...[
                                  const SizedBox(height: 8),
                                  AppPill(
                                    label: '渲染 · ${kotvPlayerRenderLabel(_renderMode)}',
                                    height: 40,
                                    onTap: () => unawaited(_pickRender()),
                                  ),
                                ],
                                const SizedBox(height: 8),
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
                                const SizedBox(height: 8),
                                AppPill(label: '打开设置页', height: 40, onTap: () => goKotvPage(ref, KotvPage.settings)),
                                const SizedBox(height: 16),
                                Text('直播源', style: TextStyle(color: p.muted)),
                                const SizedBox(height: 8),
                                for (var i = 0; i < _sources.length; i++)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 6),
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
                                const SizedBox(height: 12),
                                  AppPill(
                                  label: '配置直播源',
                                  height: 40,
                                  onTap: () async {
                                    await showLivePicker(context, ref);
                                    await _bootstrap(forceLoad: true);
                                  },
                                ),
                                const SizedBox(height: 8),
                                AppPill(label: '关闭面板', height: 40, onTap: () => setState(() => _rightOpen = false)),
                              ],
                            ),
                          );
                          }),
                        ),
                      ),
                    ),
                  // 底栏信息条（频道名）；无回看播控时贴底，不挡上下换台。
                  if (_channelInfoVisible && !_leftOpen && !_rightOpen && (!_catchup || !_catchupChrome))
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
            onNews: () => showAppNews(context, remoteHint(ref)),
            title: title,
          ),
          AspectRatio(
          aspectRatio: 16 / 9,
          child: ColoredBox(
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
                    onPressed: () => _selectGroup(i),
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
                    color: sel ? p.selected.withOpacity(0.28) : p.pillBg.withOpacity(0.55),
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
                  itemBuilder: (_, i) => _epgProgramTile(i, land: false, wScale: 1, portrait: true),
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
                singleFrame: true,
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
