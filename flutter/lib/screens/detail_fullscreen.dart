import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../player/danmaku_layer.dart';
import '../player/external_player.dart';
import '../player/fullscreen_mode.dart';
import '../player/fullscreen_gesture.dart';
import '../player/kotv_playback.dart';
import '../player/kotv_platform.dart';
import '../player/kotv_player_factory.dart';
import '../player/kotv_win_chrome.dart';
import '../player/native_mpv_playback.dart';
import '../player/tv_remote_keys.dart';
import '../remote/remote_bridge.dart';
import '../theme/kotv_theme.dart';
import '../theme/layout_scale.dart';
import '../widgets/buffering_overlay.dart';
import '../widgets/vod_player_chrome.dart';
import 'shell.dart';

/// 详情页全屏：MPV / FVP / Exo 共用同一套顶底控件。
class DetailFullscreenPage extends StatefulWidget {
  const DetailFullscreenPage({
    super.key,
    required this.playback,
    required this.videoChild,
    required this.vodName,
    required this.title,
    this.embedded = false,
    this.onExitEmbedded,
    this.onDoubleTapEmbedded,
    this.episodes = const [],
    this.epIdx = -1,
    this.onSelectEp,
    this.onNext,
    this.onPrev,
    this.playUrl = '',
    this.decodeMode = 'auto',
    this.renderMode = 'surface',
    this.aspect = const AspectSpec(key: 'default', fit: BoxFit.contain),
    this.onAspectChanged,
    this.onDecodeChanged,
    this.onRenderChanged,
    this.onPersistSetting,
    this.onLoadSettings,
    this.onPlayerStatus,
    this.onExternalPlayer,
    this.onToggleKeep,
    this.keepLabel = '收藏',
    this.onParse,
    this.onRefresh,
    this.onCast,
    this.onMini,
    this.danmakuOn = false,
    this.danmakuItems = const [],
    this.danmakuSize = 18,
    this.danmakuOpacity = 0.85,
    this.danmakuRows = 6,
    this.danmakuMaxOnScreen = 150,
    this.danmakuScrollArea = 0.5,
    this.danmakuShowScroll = true,
    this.danmakuShowTop = true,
    this.danmakuShowBottom = true,
    this.danmakuShowReverse = true,
    this.danmakuShowSpecial = true,
    this.danmakuShowPositioned = true,
    this.danmakuBold = false,
    this.danmakuDurationMs = 8000,
    this.danmakuFixedDurationMs = 5000,
    this.danmakuLineSpacing = 1.4,
    this.danmakuStrokeMode = 'outline',
    this.danmakuColorMode = 'original',
    this.danmakuFontFamily = 'default',
    this.danmakuRowsTop = 3,
    this.danmakuRowsBottom = 3,
    this.danmakuScrollGap = 0.08,
    this.danmakuStrokeWidth = 0.12,
    this.danmakuShadowOpacity = 0.5,
    this.danmakuProjectionOffsetX = 0.08,
    this.danmakuProjectionOffsetY = 0.08,
    this.danmakuProjectionOpacity = 0.2,
    this.danmakuSources = const [],
    this.danmakuSourceIdx = 0,
    this.onDanmakuSourceChanged,
    this.onDanmakuSearch,
    this.onDanmakuSettingsChanged,
    this.ambientOn = false,
    this.onAmbientChanged,
    this.onRepeatOneChanged,
    this.stableVolumeOn = false,
    this.holdSpeed = 2.0,
    this.onAssrtSearch,
    this.offsetId = '',
    this.offsetSite = '',
    this.openingSec = 0,
    this.endingSec = 0,
    this.onOffsetsChanged,
    this.desktopFullscreen = KotvDesktopFullscreenKind.window,
    this.externalVideo = false,
    this.swipeOffset,
    this.onWinLayoutChanged,
  });

  final KotvPlayback playback;
  /// 详情页传入的同一块 PlatformView/Texture（原位全屏，不重绑 Surface）。
  final Widget videoChild;
  /// 桌面：画面由外层 Positioned 宿主绘制，本页只叠控件，避免卸树重建 Texture。
  final bool externalVideo;
  /// 外层稳定视频层跟手位移（上下滑切集）；为 null 时仅本页控件位移。
  final ValueNotifier<double>? swipeOffset;
  final String vodName;
  final String title;
  /// true：嵌在详情页内切换布局；false：独立路由（遗留）。
  final bool embedded;
  final VoidCallback? onExitEmbedded;
  /// 嵌入模式双击画面：由父页做桌面三态循环；为空则退沉浸。
  final VoidCallback? onDoubleTapEmbedded;
  final List<String> episodes;
  final int epIdx;
  final void Function(int idx)? onSelectEp;
  final VoidCallback? onNext;
  final VoidCallback? onPrev;
  final String playUrl;
  final String decodeMode;
  final String renderMode;
  final AspectSpec aspect;
  final ValueChanged<AspectSpec>? onAspectChanged;
  final ValueChanged<String>? onDecodeChanged;
  final ValueChanged<String>? onRenderChanged;
  final Future<void> Function(String key, String value)? onPersistSetting;
  final Future<Map<String, String>> Function()? onLoadSettings;
  final Future<Map<String, dynamic>> Function()? onPlayerStatus;
  /// 返回 false 表示选择器被关掉，外部播放器没有打开。
  final Future<bool> Function(String playerVal)? onExternalPlayer;
  final Future<String> Function()? onToggleKeep;
  final String keepLabel;
  final VoidCallback? onParse;
  final VoidCallback? onRefresh;
  final VoidCallback? onCast;
  final VoidCallback? onMini;
  final bool danmakuOn;
  final List<DanmakuItem> danmakuItems;
  final double danmakuSize;
  final double danmakuOpacity;
  final int danmakuRows;
  final int danmakuMaxOnScreen;
  final double danmakuScrollArea;
  final bool danmakuShowScroll;
  final bool danmakuShowTop;
  final bool danmakuShowBottom;
  final bool danmakuShowReverse;
  final bool danmakuShowSpecial;
  final bool danmakuShowPositioned;
  final bool danmakuBold;
  final int danmakuDurationMs;
  final int danmakuFixedDurationMs;
  final double danmakuLineSpacing;
  final String danmakuStrokeMode;
  final String danmakuColorMode;
  final String danmakuFontFamily;
  final int danmakuRowsTop;
  final int danmakuRowsBottom;
  final double danmakuScrollGap;
  final double danmakuStrokeWidth;
  final double danmakuShadowOpacity;
  final double danmakuProjectionOffsetX;
  final double danmakuProjectionOffsetY;
  final double danmakuProjectionOpacity;
  final List<DanmakuSource> danmakuSources;
  final int danmakuSourceIdx;
  final ValueChanged<int>? onDanmakuSourceChanged;
  final VoidCallback? onDanmakuSearch;
  final VoidCallback? onDanmakuSettingsChanged;
  final bool ambientOn;
  final ValueChanged<bool>? onAmbientChanged;
  final ValueChanged<bool>? onRepeatOneChanged;
  final bool stableVolumeOn;
  final double holdSpeed;
  final Future<void> Function()? onAssrtSearch;
  final String offsetId;
  final String offsetSite;
  final int openingSec;
  final int endingSec;
  final void Function(int openingSec, int endingSec)? onOffsetsChanged;
  /// PC：铺满当前窗口 / 占满整块屏幕；移动端忽略。
  final KotvDesktopFullscreenKind desktopFullscreen;
  /// Win7：选集开合时通知外层重裁画面 HWND。
  final VoidCallback? onWinLayoutChanged;

  @override
  State<DetailFullscreenPage> createState() => DetailFullscreenPageState();
}

class DetailFullscreenPageState extends State<DetailFullscreenPage>
    with SingleTickerProviderStateMixin {
  bool _showChrome = false;
  MouseCursor _mouseCursor = SystemMouseCursors.basic;
  /// 是否在全屏 MouseRegion 内；仅用于「从窗外进入」边沿，避免窗内移动误取消关选集定时器。
  bool _pointerIn = false;
  late AspectSpec _aspect = widget.aspect;
  late String _decodeMode = widget.decodeMode;
  late String _renderMode = widget.renderMode;
  late int _epIdx = widget.epIdx;
  late bool _danmakuOn = widget.danmakuOn;
  late bool _ambientOn = widget.ambientOn;
  Timer? _hideTimer;
  double? _rateBeforeHold;
  bool _holdingSpeed = false;
  String? _holdSpeedHint;
  Timer? _hintTimer;
  /// 指针停在顶底栏，或非桌面遥控焦点停在栏内。桌面鼠标离开后不因焦点停住隐藏。
  bool _chromeHold = false;
  /// 非用户意图时保持沉浸（换集过渡 / 关选集后）；挡住 pause、hover、hold 亮栏。
  bool _chromeStayImmersive = false;
  /// 为 true 时，恢复 playing 后解除 [_chromeStayImmersive]（换集）；关选集后为 false，须用户点出。
  bool _clearImmersiveOnPlay = false;
  /// 本 pointer 已长按倍速：抬手勿当单击亮栏。
  bool _suppressTapAfterHold = false;
  /// 遥控上键已进入临时倍速：抬键只恢复倍速，不走短按亮栏。
  bool _remoteHoldSpeed = false;
  DateTime? _lastTapAt;
  bool? _playingForChrome;
  final GlobalKey<VodFullscreenChromeState> _chromeKey = GlobalKey<VodFullscreenChromeState>();
  final FocusNode _winKeyFallback = FocusNode(debugLabel: 'win7ChromeKey');

  /// 上下滑切集：跟手位移 + 松手吸附/切集。
  double _dragDy = 0;
  bool _dragging = false;
  int? _swipePointer;
  Offset? _swipeDownAt;
  VelocityTracker? _swipeVelocity;
  bool _pointerSwiping = false;
  late final AnimationController _swipeAnim;
  Animation<double>? _swipeTween;
  String? _swipeHint;
  DateTime? _lastSwipeAt;
  bool _forcedLandscape = false;
  bool _showForceLandscape = false;

  /// 栏隐时左右键快进/快退：按下累加预览，抬键提交。
  Duration? _seekPreviewBase;
  Duration _seekPreviewDelta = Duration.zero;

  /// 非电视：seek / 侧边亮音 / 切集；触/笔另支持捏合。电视仅竖滑切集。
  KotvFsMode _gMode = KotvFsMode.none;
  KotvSideGestureSession? _sideGesture;
  double _pinchScale = 1.0;
  double _pinchStartScale = 1.0;
  double _pinchSpan0 = 0;
  Offset _pinchFocal = Offset.zero;
  final Map<int, Offset> _pointers = {};
  bool _gestureLocked = false;
  Timer? _wheelHudTimer;

  /// 点播全屏播放器手势（非电视）。
  bool get _playerGestures => !KotvLayout.television;

  /// 锁屏按钮：随手机/平板触控 chrome，不强行加桌面锁。
  bool get _gestureLockUi => !KotvLayout.television && !kotvIsDesktop() && !kIsWeb;

  Future<void> _setPlayerVolume(double percent) => widget.playback.setVolume(percent);

  String get _title {
    if (_epIdx >= 0 && _epIdx < widget.episodes.length) {
      return '${widget.vodName} · ${widget.episodes[_epIdx]}';
    }
    return widget.vodName.isNotEmpty ? widget.vodName : widget.title;
  }

  bool _onGlobalBackKey(KeyEvent event) {
    if (event is! KeyDownEvent || !kotvIsBackKey(event.logicalKey)) return false;
    if (!mounted) return false;
    // 栏/选集仍开时交给页内 Focus.onKeyEvent，避免抢走 Overlay 菜单的 ESC。
    if (_showChrome || _epOpen) return false;
    // 栏隐后 primary 可能离开页内 Focus；仍用同一套返回分层。
    final back = detailImmersiveBack;
    if (back != null) {
      unawaited(back());
      return true;
    }
    unawaited(_exitFullscreen());
    return true;
  }

  @override
  void initState() {
    super.initState();
    detailFullscreenDismissLayer = _dismissOneLayer;
    HardwareKeyboard.instance.addHandler(_onGlobalBackKey);
    _swipeAnim = AnimationController(vsync: this, duration: const Duration(milliseconds: 280))
      ..addListener(() {
        final t = _swipeTween;
        if (t == null || !mounted) return;
        setState(() => _setDragDy(t.value));
      });
    _playingForChrome = widget.playback.playing;
    _bindPlaybackStreams(widget.playback);
    // 自动下一集由详情页负责；此处勿再听 completed（会与父页抢跳导致连跳）
    // 嵌入详情 Stack：系统栏/方向由父页独占，勿与 _enter/_exitImmersive 叠调（易方向抖动卡死）。
    if (!widget.embedded) {
      if (!kotvIsDesktop() && !kIsWeb && !KotvLayout.television) {
        // 先锁竖屏再进沉浸：锁方向常会把系统栏拉回来。电视保持横屏。
        unawaited(() async {
          await kotvLockPortrait();
          await kotvEnterSystemFullscreenAfterLayout(widget.desktopFullscreen);
        }());
      } else {
        unawaited(kotvEnterSystemFullscreenAfterLayout(widget.desktopFullscreen));
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _refreshForceLandscapeBtn();
      // 播放中进全屏默认沉浸；已暂停则亮栏方便继续播。
      if (widget.playback.playing) {
        _hideChromeImmersive();
      } else {
        _setChrome(show: true, hideCursor: false);
      }
      _bindWinChrome();
    });
  }

  int _winChromeToken = 0;
  int _winSleepMinutes = 0;
  Timer? _winSleepTimer;
  bool _winStableVolume = false;
  bool _winLoopSkip = true;
  String _winKeepLabel = '收藏';

  void _bindWinChrome() {
    if (!KotvWinChrome.isNeeded) return;
    _winStableVolume = widget.stableVolumeOn;
    _winKeepLabel = widget.keepLabel;
    _winChromeToken = KotvWinChrome.bind(_onWinChromeEvent);
    _syncWinChrome();
  }

  List<Map<String, dynamic>> _winMoreItems() {
    final srcIdx = widget.danmakuSourceIdx.clamp(0, widget.danmakuSources.isEmpty ? 0 : widget.danmakuSources.length - 1);
    final srcName = widget.danmakuSources.isEmpty ? '' : widget.danmakuSources[srcIdx].name;
    final renderLabel = _renderMode == 'texture' ? 'Texture' : 'Surface（推荐，HDR）';
    return KotvWinChrome.vodMoreItems(
      rate: widget.playback.rate,
      danmakuOn: _danmakuOn,
      ambientOn: _ambientOn,
      repeatOne: widget.playback.repeatOne,
      stableVolume: _winStableVolume,
      supportsStableVolume: widget.playback.supportsStableVolume,
      loopSkip: _winLoopSkip,
      sleepMinutes: _winSleepMinutes,
      keepLabel: _winKeepLabel,
      renderLabel: renderLabel,
      supportsRenderMode: widget.playback.supportsRenderMode,
      canSwitchPlayer: kotvCanSwitchPlayer(live: false),
      danmakuSourceCount: widget.danmakuSources.length,
      danmakuSourceName: srcName,
      hasDanmakuSearch: widget.onDanmakuSearch != null,
      hasCast: widget.onCast != null,
      hasMini: widget.onMini != null,
      hasParse: widget.onParse != null,
      hasKeep: widget.onToggleKeep != null,
    );
  }

  Future<void> _winPersist(String key, String value) async {
    await widget.onPersistSetting?.call(key, value);
  }

  Future<void> _winOpenDanmakuSettings() async {
    await KotvWinChrome.showDanmakuSettingsSheet(
      danmakuOn: _danmakuOn,
      showScroll: widget.danmakuShowScroll,
      showTop: widget.danmakuShowTop,
      showBottom: widget.danmakuShowBottom,
      showReverse: widget.danmakuShowReverse,
      showPositioned: widget.danmakuShowPositioned,
      showSpecial: widget.danmakuShowSpecial,
      bold: widget.danmakuBold,
      fontSize: widget.danmakuSize,
      opacity: widget.danmakuOpacity,
      rows: widget.danmakuRows,
      maxOnScreen: widget.danmakuMaxOnScreen,
      scrollArea: widget.danmakuScrollArea,
      durationMs: widget.danmakuDurationMs,
      fixedDurationMs: widget.danmakuFixedDurationMs,
    );
  }

  Future<void> _winOpenPlayerPicker() async {
    if (!kotvCanSwitchPlayer(live: false)) return;
    Map<String, dynamic> status = {};
    try {
      status = await widget.onPlayerStatus?.call() ?? {};
    } catch (_) {}
    final cur = kotvClampPlayerVal('${status['current'] ?? ''}'.trim(), live: false);
    final opts = await kotvInstalledPlayerOptions(live: false, engineStatus: status);
    if (!mounted) return;
    await KotvWinChrome.showPlayerPickerSheet(
      currentId: cur,
      options: opts,
      subtitle: '当前：${flutterPlayerLabel(cur)}',
    );
  }

  Future<void> _winApplyPlayer(String id) async {
    final next = kotvClampPlayerVal(id, live: false);
    await _winPersist('player', next);
    if (kotvIsExternalPlayer(next)) {
      final opened = await widget.onExternalPlayer?.call(next);
      if (opened == false) return;
      unawaited(_exitFullscreen());
      return;
    }
    _syncWinChrome();
  }

  void _onWinChromeEvent(Map<String, dynamic> e) {
    if (!mounted) return;
    final type = e['type'] as String? ?? '';
    switch (type) {
      case 'pointerHold':
        _onChromeHoldChanged(e['on'] == true);
        break;
      case 'hover':
        // 桌面画面悬停亮栏（对齐 _onHover）
        _bumpChrome(intentional: true);
        break;
      case 'tap':
        _handleVideoTap();
        break;
      case 'doubleTap':
        if (widget.embedded && kotvIsDesktop()) {
          (widget.onDoubleTapEmbedded ?? widget.onExitEmbedded)?.call();
        } else {
          unawaited(_exitFullscreen());
        }
        break;
      case 'holdSpeed':
        if (e['on'] == true) {
          _startHoldSpeed();
        } else {
          _stopHoldSpeed();
        }
        break;
      case 'fxPreview':
        final on = e['on'] == true;
        final kind = e['kind'] as String? ?? '';
        unawaited(widget.playback.setFxPreview(
          videoOriginal: kind == 'videoEq' ? on : null,
          audioOriginal: kind == 'audioFx' ? on : null,
        ));
        break;
      case 'key':
        final ke = KotvWinChrome.keyEventFromMap(e);
        if (ke != null) {
          _onKey(FocusManager.instance.primaryFocus ?? _winKeyFallback, ke);
        }
        break;
      case 'toggle':
      case 'togglePlay':
        unawaited(widget.playback.playOrPause());
        break;
      case 'seekFraction':
        final frac = (e['value'] as num?)?.toDouble() ?? 0;
        final dur = widget.playback.duration;
        if (dur.inMilliseconds <= 0) break;
        final target = Duration(
            milliseconds: (dur.inMilliseconds * frac.clamp(0.0, 1.0)).round());
        if (e['commit'] == false) {
          setState(() {
            _seekPreviewBase ??= widget.playback.position;
            _seekPreviewDelta = target - _seekPreviewBase!;
          });
          break;
        }
        _seekPreviewBase = null;
        _seekPreviewDelta = Duration.zero;
        unawaited(widget.playback.seek(target));
        if (mounted) setState(() {});
        break;
      case 'prev':
        widget.onPrev?.call();
        break;
      case 'next':
        widget.onNext?.call();
        break;
      case 'replay':
        unawaited(() async {
          await widget.playback.seek(Duration.zero);
          await widget.playback.play();
        }());
        break;
      case 'speed':
        final v = (e['value'] as num?)?.toDouble() ?? (e['rate'] as num?)?.toDouble();
        if (v != null && v > 0) {
          unawaited(widget.playback.setRate(v));
        } else {
          unawaited(widget.playback.setRate(KotvWinChrome.nextSpeed(widget.playback.rate)));
        }
        _syncWinChrome();
        break;
      case 'aspect':
        final key = e['id'] as String? ?? 'default';
        const table = <String, AspectSpec>{
          'default': AspectSpec(key: 'default', fit: BoxFit.contain),
          'fill': AspectSpec(key: 'fill', fit: BoxFit.fill),
          'zoom': AspectSpec(key: 'zoom', fit: BoxFit.cover),
          '16:9': AspectSpec(key: '16:9', fit: BoxFit.fill, ratio: 16 / 9),
          '4:3': AspectSpec(key: '4:3', fit: BoxFit.fill, ratio: 4 / 3),
        };
        final a = table[key] ?? table['default']!;
        setState(() => _aspect = a);
        widget.onAspectChanged?.call(a);
        _syncWinChrome();
        break;
      case 'decode':
        final mode = e['id'] as String? ?? 'auto';
        unawaited(_onDecode(mode));
        break;
      case 'direct':
        unawaited(_winPersist(
          'mpvDirect',
          (e['on'] == true) ? 'true' : 'false',
        ));
        break;
      case 'offsets':
        final open = (e['openingSec'] as num?)?.toInt() ?? widget.openingSec;
        final end = (e['endingSec'] as num?)?.toInt() ?? widget.endingSec;
        widget.onOffsetsChanged?.call(open, end);
        _syncWinChrome();
        break;
      case 'track':
        unawaited(_onWinTrack(
          e['kind'] as String? ?? '',
          e['id'] as String? ?? '',
        ));
        break;
      case 'episodes':
        _toggleEpisodes();
        break;
      case 'closeEpisodes':
        if (KotvWinChrome.isNeeded) {
          setState(() => _winEpOpen = false);
          _onEpisodesClosed();
        } else {
          _chromeKey.currentState?.closeEpisodes();
        }
        _syncWinChrome();
        break;
      case 'episode':
        final idx = (e['index'] as num?)?.toInt() ?? -1;
        if (idx >= 0 && idx < widget.episodes.length) {
          widget.onSelectEp?.call(idx);
        }
        break;
      case 'more':
      case 'sheet':
        // 原生已开子 sheet 时勿再弹 Flutter/二次原生层
        if (e['nativeSheet'] == true) break;
        _onWinSheet(e['id'] as String? ?? '', e['kind'] as String? ?? e['sheet'] as String? ?? '');
        break;
      case 'toggleItem':
        unawaited(_onWinToggleItem(e['id'] as String? ?? '', e['on'] == true));
        break;
      case 'slider':
        unawaited(_onWinSlider(
          e['id'] as String? ?? '',
          (e['value'] as num?)?.toDouble() ?? 0,
          commit: e['commit'] == true,
        ));
        break;
      case 'pickPlayer':
        unawaited(_winApplyPlayer(e['id'] as String? ?? ''));
        break;
      case 'sheetClose':
        unawaited(widget.playback.setFxPreview(videoOriginal: false, audioOriginal: false));
        break;
      case 'dismiss':
      case 'back':
        if (!_dismissOneLayer()) unawaited(_exitFullscreen());
        break;
      case 'exit':
        unawaited(_exitFullscreen());
        break;
    }
  }

  Future<void> _onWinToggleItem(String id, bool on) async {
    switch (id) {
      case 'danmaku':
        setState(() => _danmakuOn = on);
        await KotvWinChrome.persistDanmakuToggle(id: id, on: on, persist: _winPersist);
        widget.onDanmakuSettingsChanged?.call();
        break;
      case 'ambient':
        setState(() => _ambientOn = on);
        widget.onAmbientChanged?.call(on);
        await _winPersist('playerAmbient', on ? 'true' : 'false');
        break;
      case 'repeat':
        widget.onRepeatOneChanged?.call(on);
        break;
      case 'stableVolume':
        setState(() => _winStableVolume = on);
        await _winPersist('playerStableVolume', on ? 'true' : 'false');
        break;
      case 'loopSkip':
        setState(() => _winLoopSkip = on);
        await _winPersist('playerSkipOpeningEnding', on ? 'true' : 'false');
        break;
      default:
        if (await KotvWinChrome.persistDanmakuToggle(id: id, on: on, persist: _winPersist)) {
          widget.onDanmakuSettingsChanged?.call();
        }
        break;
    }
    _syncWinChrome();
  }

  Future<void> _onWinSlider(String id, double value, {required bool commit}) async {
    if (id == 'volume') {
      unawaited(widget.playback.setVolume(value.clamp(0, 100)));
      if (commit) {
        await _winPersist('playerVolume', '${value.round()}');
        _syncWinChrome();
      }
      return;
    }
    if (!commit) return;
    const eqKeys = {
      'videoBrightness',
      'videoContrast',
      'videoSaturation',
      'videoSharpness',
      'videoTemperature',
      'audioDialogue',
      'audioBalance',
      'audioOffsetMs',
    };
    if (eqKeys.contains(id)) {
      await _winPersist(id, '${value.round()}');
      widget.onDanmakuSettingsChanged?.call();
      return;
    }
    if (await KotvWinChrome.persistDanmakuSlider(id: id, value: value, persist: _winPersist)) {
      widget.onDanmakuSettingsChanged?.call();
      _syncWinChrome();
    }
  }

  Future<void> _onWinTrack(String kind, String id) async {
    if (kind.isEmpty) return;
    if (id == 'open' || id.isEmpty) {
      await _winOpenTrackSheet(kind);
      return;
    }
    final pb = widget.playback;
    switch (kind) {
      case 'subtitle':
        if (id == 'off' || id == 'none') {
          await pb.setSubtitleTrack('');
        } else {
          await pb.setSubtitleTrack(id);
        }
        break;
      case 'audio':
        await pb.setAudioTrack(id);
        break;
      case 'video':
        await pb.setVideoTrack(id);
        break;
    }
    _syncWinChrome();
  }

  Future<void> _winOpenTrackSheet(String kind) async {
    final pb = widget.playback;
    final items = <Map<String, dynamic>>[];
    String title = '轨道';
    String? selected;
    if (kind == 'subtitle') {
      title = '字幕';
      selected = pb.currentSubtitleId;
      items.add(KotvWinChrome.lineItem(
        id: 'off',
        label: '关闭字幕',
        chevron: false,
        trailing: kotvSubtitleIsOff(selected) ? '✓' : '',
      ));
      items.add(KotvWinChrome.lineItem(
        id: 'auto',
        label: '自动',
        chevron: false,
        trailing: kotvSubtitleIsAuto(selected) ? '✓' : '',
      ));
      for (final t in pb.subtitleTracks) {
        items.add(KotvWinChrome.lineItem(
          id: t.id,
          label: t.label,
          chevron: false,
          trailing: t.id == selected ? '✓' : '',
        ));
      }
    } else if (kind == 'audio') {
      title = '音轨';
      selected = pb.currentAudioId;
      items.add(KotvWinChrome.lineItem(
        id: 'auto',
        label: '自动',
        chevron: false,
        trailing: kotvAudioIsAuto(selected) ? '✓' : '',
      ));
      for (final t in pb.audioTracks) {
        items.add(KotvWinChrome.lineItem(
          id: t.id,
          label: t.label,
          chevron: false,
          trailing: t.id == selected ? '✓' : '',
        ));
      }
    } else if (kind == 'video') {
      title = '视频轨';
      selected = pb.currentVideoId;
      items.add(KotvWinChrome.lineItem(
        id: 'auto',
        label: '自动',
        chevron: false,
        trailing: (selected == null || selected == 'auto' || selected.isEmpty) ? '✓' : '',
      ));
      for (final t in pb.videoTracks) {
        items.add(KotvWinChrome.lineItem(
          id: t.id,
          label: t.label,
          chevron: false,
          trailing: t.id == selected ? '✓' : '',
        ));
      }
    } else {
      return;
    }
    await KotvWinChrome.showSheet(kind: kind, title: title, items: items);
  }

  void _onWinSheet(String id, String kind) {
    if (id.isEmpty) return;
    if (kind == 'player' || id.startsWith('outie#') || id == 'mpv' || id == 'fvp' || id == 'exo' || id == 'html') {
      // pickPlayer 已处理；sheet 双发时忽略
    }
    switch (kind) {
      case 'videoEq':
        if (id == 'reset') {
          for (final k in const [
            'videoBrightness',
            'videoContrast',
            'videoSaturation',
            'videoSharpness',
            'videoTemperature',
          ]) {
            unawaited(_winPersist(k, '0'));
          }
          widget.onDanmakuSettingsChanged?.call();
          return;
        }
        unawaited(_winPersist('videoEq', id));
        widget.onDanmakuSettingsChanged?.call();
        return;
      case 'audioFx':
        unawaited(_winPersist('audioEq', id));
        widget.onDanmakuSettingsChanged?.call();
        return;
      case 'speed':
        final v = double.tryParse(id);
        if (v != null) unawaited(widget.playback.setRate(v));
        return;
      case 'sleep':
        _winArmSleep(int.tryParse(id) ?? 0);
        return;
      case 'danmakuSource':
        final i = int.tryParse(id);
        if (i != null) widget.onDanmakuSourceChanged?.call(i);
        return;
      case 'render':
        unawaited(_winPersist('playerRender', id));
        widget.onRenderChanged?.call(id);
        return;
      case 'playInfo':
        return;
    }
    switch (id) {
      case 'open':
        _syncWinChrome();
        break;
      case 'videoEq':
      case 'audioFx':
        // 壳内 pill+滑条自绘；仅当未带 nativeSheet 误入时忽略，勿开列表版
        break;
      case 'danmakuSettings':
        unawaited(_winOpenDanmakuSettings());
        break;
      case 'danmakuSource':
        unawaited(KotvWinChrome.showChoiceSheet(
          kind: 'danmakuSource',
          title: '选择弹幕源',
          options: [
            for (var i = 0; i < widget.danmakuSources.length; i++)
              ('$i', widget.danmakuSources[i].name),
          ],
          selectedId: '${widget.danmakuSourceIdx}',
        ));
        break;
      case 'danmakuSearch':
        widget.onDanmakuSearch?.call();
        break;
      case 'sleep':
        unawaited(KotvWinChrome.showChoiceSheet(
          kind: 'sleep',
          title: '休眠定时器',
          options: KotvWinChrome.sleepOptions,
          selectedId: '$_winSleepMinutes',
        ));
        break;
      case 'speed':
        unawaited(KotvWinChrome.showChoiceSheet(
          kind: 'speed',
          title: '倍速',
          options: [
            for (final s in KotvWinChrome.vodSpeeds)
              (
                '$s',
                'x${s.toStringAsFixed(s == s.roundToDouble() ? 0 : 1)}',
              ),
          ],
          selectedId: '${widget.playback.rate}',
        ));
        break;
      case 'player':
        unawaited(_winOpenPlayerPicker());
        break;
      case 'render':
        unawaited(KotvWinChrome.showRenderSheet(_renderMode));
        break;
      case 'playInfo':
        unawaited(_winShowPlayInfo());
        break;
      case 'episodes':
        _toggleEpisodes();
        break;
      case 'cast':
        widget.onCast?.call();
        break;
      case 'mini':
        widget.onMini?.call();
        break;
      case 'parse':
        widget.onParse?.call();
        break;
      case 'keep':
        unawaited(() async {
          final label = await widget.onToggleKeep?.call();
          if (mounted && label != null && label.isNotEmpty) {
            setState(() => _winKeepLabel = label);
            _syncWinChrome();
          }
        }());
        break;
      case 'replay':
        if (widget.onRefresh != null) {
          widget.onRefresh!();
        } else {
          unawaited(() async {
            await widget.playback.seek(Duration.zero);
            await widget.playback.play();
          }());
        }
        break;
      case 'exit':
        unawaited(_exitFullscreen());
        break;
    }
  }

  void _winArmSleep(int minutes) {
    _winSleepTimer?.cancel();
    _winSleepMinutes = minutes;
    if (minutes <= 0) {
      _syncWinChrome();
      return;
    }
    _winSleepTimer = Timer(Duration(minutes: minutes), () {
      if (!mounted) return;
      unawaited(widget.playback.pause());
      setState(() => _winSleepMinutes = 0);
      _syncWinChrome();
    });
    _syncWinChrome();
  }

  Future<void> _winShowPlayInfo() async {
    Map<String, dynamic> status = {};
    try {
      status = await widget.onPlayerStatus?.call() ?? {};
    } catch (_) {}
    if (!mounted) return;
    final lines = <(String, String)>[
      ('engine', '${status['engine'] ?? widget.playback.engineLabel}'),
      ('url', widget.playUrl.isEmpty ? '（无）' : widget.playUrl),
      ('size', '${widget.playback.width}x${widget.playback.height}'),
      ('rate', '${widget.playback.rate}'),
    ];
    await KotvWinChrome.showSheet(
      kind: 'playInfo',
      title: '播放信息',
      items: [
        for (final e in lines)
          KotvWinChrome.lineItem(id: e.$1, label: '${e.$1}: ${e.$2}', chevron: false),
      ],
    );
  }

  void _syncWinChrome() {
    if (!KotvWinChrome.isNeeded || !mounted) return;
    // 选集打开时不亮顶底栏（与 Flutter VodFullscreenChrome 一致）。
    final chromeOn = _showChrome && !_epOpen;
    unawaited(KotvWinChrome.pushVod(
      playback: widget.playback,
      title: '${widget.vodName}${widget.title.isNotEmpty ? ' · ${widget.title}' : ''}',
      subtitle: widget.title,
      episodes: List<String>.from(widget.episodes),
      episodeSelected: _epIdx,
      chromeVisible: chromeOn,
      episodesVisible: _epOpen,
      danmakuOn: _danmakuOn,
      danmakuItems: widget.danmakuItems,
      moreItems: _winMoreItems(),
      danmakuFontSize: widget.danmakuSize,
      danmakuOpacity: widget.danmakuOpacity,
      danmakuDurationMs: widget.danmakuDurationMs,
      danmakuFixedDurationMs: widget.danmakuFixedDurationMs,
      danmakuRows: widget.danmakuRows,
      danmakuShowScroll: widget.danmakuShowScroll,
      danmakuShowTop: widget.danmakuShowTop,
      danmakuShowBottom: widget.danmakuShowBottom,
      danmakuShowReverse: widget.danmakuShowReverse,
      openingSec: widget.openingSec,
      endingSec: widget.endingSec,
      aspect: _aspect.key,
      decodeMode: _decodeMode,
      showDirect: kotvShowDirectOutput(widget.playback, _decodeMode),
      directOn: widget.playback.directOutput,
    ));
  }

  void _bindPlaybackStreams(KotvPlayback pb) {
    pb.addListener(_onPlaybackChanged);
  }

  @override
  void didUpdateWidget(covariant DetailFullscreenPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.decodeMode != widget.decodeMode) _decodeMode = widget.decodeMode;
    if (oldWidget.renderMode != widget.renderMode) _renderMode = widget.renderMode;
    if (oldWidget.aspect.key != widget.aspect.key) _aspect = widget.aspect;
    if (oldWidget.epIdx != widget.epIdx) _epIdx = widget.epIdx;
    if (oldWidget.danmakuOn != widget.danmakuOn) _danmakuOn = widget.danmakuOn;
    if (oldWidget.ambientOn != widget.ambientOn) _ambientOn = widget.ambientOn;
    if (!identical(oldWidget.playback, widget.playback)) {
      oldWidget.playback.removeListener(_onPlaybackChanged);
      _playingForChrome = widget.playback.playing;
      _bindPlaybackStreams(widget.playback);
      _refreshForceLandscapeBtn();
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onGlobalBackKey);
    if (detailFullscreenDismissLayer == _dismissOneLayer) {
      detailFullscreenDismissLayer = null;
    }
    _hideTimer?.cancel();
    _hintTimer?.cancel();
    _wheelHudTimer?.cancel();
    _swipeAnim.dispose();
    _winKeyFallback.dispose();
    widget.playback.removeListener(_onPlaybackChanged);
    _winSleepTimer?.cancel();
    if (KotvWinChrome.isNeeded) {
      KotvWinChrome.unbind(_winChromeToken);
      _winChromeToken = 0;
    }
    // 嵌入模式由父页恢复系统栏；此处再调会与 _exitImmersiveFullscreen 叠成方向竞态。
    if (!widget.embedded) {
      unawaited(_restoreChrome());
    }
    super.dispose();
  }

  void _onPlaybackChanged() {
    _refreshForceLandscapeBtn();
    if (KotvWinChrome.isNeeded) _syncWinChrome();
    final playing = widget.playback.playing;
    // 位置/缓冲会频繁 notify；只有播/停变化才动控件，否则隐藏计时会被不停重置。
    if (playing == _playingForChrome) return;
    _playingForChrome = playing;
    if (!playing) {
      _hideTimer?.cancel();
      // 换集/关选集沉浸锁：不亮栏。缓冲/卡顿时 playing 短暂 false 也不当作用户暂停。
      if (_epOpen || _chromeStayImmersive) return;
      if (widget.playback.buffering || widget.playback.stalling) return;
      _setChrome(show: true, hideCursor: false);
      return;
    }
    if (_chromeStayImmersive && _clearImmersiveOnPlay) {
      _chromeStayImmersive = false;
      _clearImmersiveOnPlay = false;
      if (_showChrome) _hideChromeImmersive();
      return;
    }
    if (_showChrome) _schedulePlayingHide();
  }

  /// 播放中收起控件时藏鼠标（手机全屏 / 占满显示器）。
  bool get _hideCursorWhenIdle =>
      widget.desktopFullscreen == KotvDesktopFullscreenKind.display || !kotvIsDesktop();

  void _setChrome({required bool show, required bool hideCursor}) {
    final cursor = hideCursor ? SystemMouseCursors.none : SystemMouseCursors.basic;
    if (show == _showChrome && cursor == _mouseCursor) return;
    setState(() {
      _showChrome = show;
      _mouseCursor = cursor;
    });
    _syncWinChrome();
  }

  void _schedulePlayingHide() {
    _hideTimer?.cancel();
    if (!widget.playback.playing || _chromeHold || _epOpen) return;
    // 桌面指针离开顶底栏后开始计时。非桌面焦点停在栏内时 onHold 拦住。
    _hideTimer = Timer(kotvPlayerOverlayHide, () {
      if (!mounted || !widget.playback.playing || _epOpen || _chromeHold) return;
      _setChrome(show: false, hideCursor: _hideCursorWhenIdle);
    });
  }

  /// 沉浸：关顶底栏（换集 / 关选集后共用）。
  void _hideChromeImmersive() {
    _hideTimer?.cancel();
    _chromeHold = false;
    _setChrome(show: false, hideCursor: _hideCursorWhenIdle && widget.playback.playing);
  }

  /// 保持沉浸并挡住非用户意图的亮栏。
  /// [untilPlay]：换集过渡在恢复播放后解除；关选集后为 false，须点画面/遥控才亮。
  void _stayChromeImmersive({required bool untilPlay}) {
    _chromeStayImmersive = true;
    _clearImmersiveOnPlay = untilPlay;
    _hideChromeImmersive();
  }

  /// 换集入口（详情 [_advanceToNextEpisode] / 无缝 queuedStart / 手势切集）：挡住 pause→亮栏。
  void beginEpisodeSwitchQuiet() => _stayChromeImmersive(untilPlay: true);

  void _startHoldSpeed() {
    if (_gestureLocked || _holdingSpeed) return;
    if (!widget.playback.playing) return;
    final cur = widget.playback.rate;
    final target = widget.holdSpeed.clamp(2.0, 5.0);
    if ((cur - target).abs() < 0.05) return;
    _rateBeforeHold = cur;
    _holdingSpeed = true;
    _suppressTapAfterHold = true;
    unawaited(widget.playback.setRate(target));
    setState(() => _holdSpeedHint = '×${target.toStringAsFixed(target == target.roundToDouble() ? 0 : 1)}');
  }

  void _stopHoldSpeed() {
    if (!_holdingSpeed) return;
    final restore = _rateBeforeHold ?? 1.0;
    _holdingSpeed = false;
    _rateBeforeHold = null;
    unawaited(widget.playback.setRate(restore));
    if (mounted) setState(() => _holdSpeedHint = null);
  }

  /// 亮顶底栏。非 [intentional]：栏隐不 reveal，仅栏已显续命；尊重沉浸锁。
  void _bumpChrome({bool intentional = false}) {
    if (_epOpen) return;
    if (!intentional) {
      if (_chromeStayImmersive) return;
      if (!_showChrome) return;
      _schedulePlayingHide();
      return;
    }
    _chromeStayImmersive = false;
    _clearImmersiveOnPlay = false;
    _setChrome(show: true, hideCursor: false);
    _schedulePlayingHide();
  }

  void _onChromeHoldChanged(bool hold) {
    if (_chromeHold == hold) return;
    _chromeHold = hold;
    if (hold) {
      _hideTimer?.cancel();
      // 沉浸锁/栏隐：焦点停在栏位也不亮栏。
      if (!_chromeStayImmersive && !_epOpen && _showChrome) {
        _schedulePlayingHide();
      }
    } else {
      _schedulePlayingHide();
    }
  }

  /// 点画面：只显隐控件，不播停。控件已显示则再点一次收起。
  /// 双击：手机→播停；桌面嵌入→三态；其它→退出全屏。
  void _handleVideoTap() {
    if (_gestureLocked) return;
    final now = DateTime.now();
    final last = _lastTapAt;
    _lastTapAt = now;
    if (last != null && now.difference(last) < kDoubleTapTimeout) {
      _lastTapAt = null;
      if (widget.embedded && kotvIsDesktop()) {
        (widget.onDoubleTapEmbedded ?? widget.onExitEmbedded)?.call();
        return;
      }
      if (!kotvIsDesktop()) {
        unawaited(widget.playback.playOrPause());
        return;
      }
      unawaited(_exitFullscreen());
      return;
    }
    _onVideoTap();
  }

  void _onVideoTap() {
    if (_gestureLocked) {
      setState(() => _gestureLocked = false);
      return;
    }
    if (_epOpen) {
      _chromeKey.currentState?.closeEpisodes();
      setState(() {});
      return;
    }
    if (_showChrome) {
      _hideTimer?.cancel();
      _setChrome(show: false, hideCursor: _hideCursorWhenIdle && widget.playback.playing);
      return;
    }
    _bumpChrome(intentional: true);
  }

  void _refreshForceLandscapeBtn() {
    if (!mounted || _forcedLandscape) {
      if (_showForceLandscape) setState(() => _showForceLandscape = false);
      return;
    }
    final pb = widget.playback;
    // 未出画/首帧缓冲中不显示，避免半透明 chip 盖 PlatformView 叠影。
    final hasFrame = pb.width > 0 && pb.height > 0 && (pb.playing || !pb.buffering);
    final show = hasFrame &&
        kotvShouldShowForceLandscape(
          screen: MediaQuery.sizeOf(context),
          videoWidth: pb.width,
          videoHeight: pb.height,
        );
    if (show != _showForceLandscape) {
      setState(() => _showForceLandscape = show);
    }
  }

  Future<void> _forceLandscape() async {
    setState(() {
      _forcedLandscape = true;
      _showForceLandscape = false;
    });
    await kotvForceLandscape();
    await kotvEnterSystemFullscreenAfterLayout(widget.desktopFullscreen);
    _bumpChrome(intentional: true);
  }

  Future<void> _lockPortraitMode() async {
    if (KotvLayout.television) return;
    setState(() => _forcedLandscape = false);
    await kotvLockPortrait();
    await kotvEnterSystemFullscreenAfterLayout(widget.desktopFullscreen);
    if (!mounted) return;
    _refreshForceLandscapeBtn();
    _bumpChrome(intentional: true);
  }

  /// 横屏后顶栏用「竖屏」切回；竖屏时不显示顶栏「横屏」（改走「全屏观看」）。
  bool get _showTopPortraitRotate => !kotvIsDesktop() && !kIsWeb && _forcedLandscape;

  Future<void> _restoreChrome() async {
    await kotvExitSystemFullscreen(
      wasDisplayFullscreen: widget.desktopFullscreen == KotvDesktopFullscreenKind.display,
    );
  }

  Future<void> _exitFullscreen() async {
    // 嵌入模式：父页负责退沉浸 + 恢复系统全屏；此处勿再 maybePop，避免叠成出详情。
    if (widget.embedded) {
      widget.onExitEmbedded?.call();
      return;
    }
    await _restoreChrome();
    if (mounted) Navigator.of(context).maybePop();
  }

  /// Win7 无 Flutter 栏时由 [_winEpOpen] 驱动原生选集；其它平台读 Flutter chrome 状态。
  bool _winEpOpen = false;
  /// 供详情页裁 HWND：选集打开时右侧给原生面板留空。
  bool get winEpisodesOpen => _epOpen;
  bool get _epOpen =>
      KotvWinChrome.isNeeded ? _winEpOpen : (_chromeKey.currentState?.epOpen ?? false);

  /// 返回关掉一层。锁屏→选集→底栏。
  bool _dismissOneLayer() {
    if (_gestureLocked) {
      setState(() => _gestureLocked = false);
      return true;
    }
    if (_epOpen) {
      if (KotvWinChrome.isNeeded) {
        setState(() => _winEpOpen = false);
        _syncWinChrome();
        widget.onWinLayoutChanged?.call();
      } else {
        _chromeKey.currentState?.closeEpisodes();
        setState(() {});
        if (_showChrome) _chromeKey.currentState?.focusPlayControl();
      }
      return true;
    }
    if (_showChrome) {
      _hideChromeImmersive();
      return true;
    }
    return false;
  }

  void _setGestureLocked(bool locked) {
    setState(() {
      _gestureLocked = locked;
      if (locked) {
        if (KotvWinChrome.isNeeded) {
          _winEpOpen = false;
        } else {
          _chromeKey.currentState?.closeEpisodes();
        }
        _hideChromeImmersive();
        _stopHoldSpeed();
        _cancelSeekPreview();
        _sideGesture = null;
      }
    });
    if (KotvWinChrome.isNeeded) _syncWinChrome();
  }

  void _toggleEpisodes() {
    if (widget.episodes.isEmpty) {
      _showChromeAndFocusPlay();
      return;
    }
    if (KotvWinChrome.isNeeded) {
      setState(() => _winEpOpen = !_winEpOpen);
      if (!_winEpOpen) _hideChromeImmersive();
      _syncWinChrome();
      widget.onWinLayoutChanged?.call();
      return;
    }
    if (_epOpen) {
      _chromeKey.currentState?.closeEpisodes();
      _hideChromeImmersive();
      setState(() {});
      return;
    }
    // 只开右侧选集，不亮顶底栏。
    _chromeKey.currentState?.openEpisodes();
    setState(() {});
  }

  void _flashSwipeHint(String text) {
    _hintTimer?.cancel();
    setState(() => _swipeHint = text);
    _hintTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _swipeHint = null);
    });
  }

  Future<void> _onDecode(String mode) async {
    setState(() => _decodeMode = mode);
    await widget.playback.setDecodeMode(mode);
    widget.onDecodeChanged?.call(mode);
  }

  Future<void> _onRender(String mode) async {
    // setRenderMode 已由控件栏调用；此处只同步 UI，并让父页立刻重建 Stable 画面层。
    if (!mounted) return;
    setState(() => _renderMode = mode);
    widget.onRenderChanged?.call(mode);
  }

  void _goNext({bool didAnimate = false}) {
    if (_epIdx + 1 >= widget.episodes.length) {
      _flashSwipeHint('已是最后一集');
      return;
    }
    // 底栏/遥控下一集：先跟手动画再切；上滑手势已在 onDone 前播完。
    if (!didAnimate) {
      unawaited(() async {
        final ok = await animateAutoNext();
        if (!ok || !mounted) return;
        _goNext(didAnimate: true);
      }());
      return;
    }
    beginEpisodeSwitchQuiet();
    widget.onNext?.call();
    final next = _epIdx + 1;
    if (next < widget.episodes.length) {
      setState(() => _epIdx = next);
    }
  }

  /// 播完自动下一集：与上滑手势同一套跟手/吸附动画。
  Future<bool> animateAutoNext() async {
    if (!mounted) return false;
    if (_epIdx + 1 >= widget.episodes.length) return false;
    if (_swipeAnim.isAnimating || _dragging) return false;
    final h = MediaQuery.sizeOf(context).height;
    if (h <= 0) return false;
    // 沉浸锁由详情 [_advanceToNextEpisode] 统一 beginEpisodeSwitchQuiet。
    final next = _epIdx + 1;
    final name = widget.episodes[next];
    _flashSwipeHint(name.isEmpty ? '下一集' : '下一集 · $name');
    _swipeAnim.stop();
    _swipeTween = null;
    setState(() {
      _dragging = true;
      _setDragDy(0);
    });
    await _animateSwipeTo(-h);
    return mounted;
  }

  void _goPrev() {
    if (_epIdx <= 0) {
      _flashSwipeHint('已是第一集');
      return;
    }
    beginEpisodeSwitchQuiet();
    widget.onPrev?.call();
    final prev = _epIdx - 1;
    if (prev >= 0) {
      setState(() => _epIdx = prev);
    }
  }

  void _selectEp(int i) {
    beginEpisodeSwitchQuiet();
    widget.onSelectEp?.call(i);
    setState(() => _epIdx = i);
  }

  bool get _canSwipeEps => !_epOpen && !_gestureLocked && widget.episodes.length > 1;

  void _setDragDy(double dy) {
    _dragDy = dy;
    final n = widget.swipeOffset;
    if (n != null && n.value != dy) n.value = dy;
  }

  void _beginSwipe() {
    _swipeAnim.stop();
    _swipeTween = null;
    setState(() {
      _dragging = true;
      _setDragDy(0);
    });
  }

  void _applySwipeDelta(double dy) {
    if (!_dragging) return;
    final h = MediaQuery.sizeOf(context).height;
    var next = _dragDy + dy;
    final blocked = (_epIdx <= 0 && next > 0) ||
        (_epIdx + 1 >= widget.episodes.length && next < 0);
    if (blocked) {
      next = _dragDy + dy * 0.35;
    }
    next = next.clamp(-h * 0.92, h * 0.92);
    setState(() => _setDragDy(next));
  }

  Future<void> _primeSideGesture(bool bright) async {
    final want = bright ? KotvFsMode.bright : KotvFsMode.volume;
    final KotvSideGestureSession? session = bright
        ? await KotvSideGestureSession.beginBright()
        : await KotvSideGestureSession.beginVolume(playerVolume: widget.playback.volume);
    if (!mounted) return;
    if (_gMode != want) return;
    if (session == null) {
      // 无亮度通道或读取失败：退出该模式，避免空 HUD 跟手。
      _gMode = KotvFsMode.none;
      return;
    }
    setState(() => _sideGesture = session);
  }

  void _applySideDrag(double upPositive, double height) {
    final s = _sideGesture;
    if (s == null) return;
    s.apply(upPositive, height);
    unawaited(s.flush(setPlayerVolume: _setPlayerVolume));
    setState(() {});
  }

  void _clearSideHud() {
    if (_sideGesture == null) return;
    setState(() => _sideGesture = null);
  }

  void _beginDragMode(KotvFsMode mode, Offset total) {
    _wheelHudTimer?.cancel();
    if (mode != KotvFsMode.seek && _seekPreviewBase != null) {
      _cancelSeekPreview();
    }
    if (mode != KotvFsMode.bright && mode != KotvFsMode.volume) {
      _clearSideHud();
    }
    switch (mode) {
      case KotvFsMode.seek:
        _gMode = KotvFsMode.seek;
        _seekPreviewBase = widget.playback.position;
        _seekPreviewDelta = Duration.zero;
        setState(() {});
        break;
      case KotvFsMode.bright:
        _gMode = KotvFsMode.bright;
        unawaited(_primeSideGesture(true));
        break;
      case KotvFsMode.volume:
        _gMode = KotvFsMode.volume;
        unawaited(_primeSideGesture(false));
        break;
      case KotvFsMode.ep:
        _gMode = KotvFsMode.ep;
        _beginSwipe();
        _pointerSwiping = true;
        _applySwipeDelta(total.dy);
        break;
      case KotvFsMode.none:
      case KotvFsMode.channel:
      case KotvFsMode.pinch:
        break;
    }
  }

  /// 滚轮/双指停顿后：提交 seek 预览并收起侧边 HUD。
  void _scheduleWheelHudSettle() {
    _wheelHudTimer?.cancel();
    _wheelHudTimer = Timer(KotvFsGesture.wheelHudSettle, () {
      if (!mounted) return;
      if (_seekPreviewBase != null) _commitSeekPreview();
      _clearSideHud();
    });
  }

  Future<void> _nudgeVolumeByDelta(double delta) async {
    if (delta == 0 || _gestureLocked) return;
    var s = _sideGesture;
    if (s == null || s.kind != 'volume') {
      s = await KotvSideGestureSession.beginVolume(playerVolume: widget.playback.volume);
      if (!mounted) return;
      setState(() => _sideGesture = s);
    }
    s.applyPercentDelta(delta);
    unawaited(s.flush(setPlayerVolume: _setPlayerVolume));
    if (mounted) setState(() {});
    _scheduleWheelHudSettle();
  }

  void _nudgeSeekByDelta(Duration step) {
    if (step == Duration.zero || _gestureLocked) return;
    _nudgeSeekPreview(step);
    _scheduleWheelHudSettle();
  }

  void _onPlayerScrollDelta(double dx, double dy, {required bool shift}) {
    if (!_playerGestures || _gestureLocked) return;
    // 拖拽/捏合进行中不抢滚轮。
    if (_gMode == KotvFsMode.pinch) return;
    if (_swipePointer != null && _gMode != KotvFsMode.none) return;
    final kind = KotvFsGesture.classifyScroll(dx: dx, dy: dy, shift: shift);
    switch (kind) {
      case KotvFsScrollKind.volume:
        unawaited(_nudgeVolumeByDelta(KotvFsGesture.volumeDeltaFromScrollDy(dy)));
        break;
      case KotvFsScrollKind.seek:
        _nudgeSeekByDelta(KotvFsGesture.seekDeltaFromScroll(dx: dx, dy: dy, shift: shift));
        break;
      case KotvFsScrollKind.none:
        break;
    }
  }

  void _onPointerSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    _onPlayerScrollDelta(e.scrollDelta.dx, e.scrollDelta.dy, shift: KotvFsGesture.shiftPressed);
  }

  void _onPointerPanZoomUpdate(PointerPanZoomUpdateEvent e) {
    // 触控板双指平移；捏合缩放不走触控板（避系统手势）。
    _onPlayerScrollDelta(e.localPanDelta.dx, e.localPanDelta.dy, shift: false);
  }

  void _onSwipePointerDown(PointerDownEvent e) {
    // 右键由全局 kotvHandleAppBack 统一处理（全屏时只退出全屏）。
    if (e.buttons != kPrimaryButton) return;
    _pointers[e.pointer] = e.position;
    if (_gestureLocked) return;
    _wheelHudTimer?.cancel();

    final touchLike = KotvFsGesture.isTouchLike(e.kind);
    if (_playerGestures && touchLike && _pointers.length >= 2) {
      _stopHoldSpeed();
      final pts = _pointers.values.toList();
      _gMode = KotvFsMode.pinch;
      _pinchStartScale = _pinchScale;
      _pinchSpan0 = (pts[0] - pts[1]).distance.clamp(1.0, 10000.0);
      _pinchFocal = Offset((pts[0].dx + pts[1].dx) / 2, (pts[0].dy + pts[1].dy) / 2);
      _swipePointer = null;
      _pointerSwiping = false;
      return;
    }

    if (_swipePointer != null) return;
    final size = MediaQuery.sizeOf(context);
    if (touchLike && KotvFsGesture.isEdge(e.position, size)) return;
    _swipePointer = e.pointer;
    _swipeDownAt = e.position;
    _swipeVelocity = VelocityTracker.withKind(e.kind)..addPosition(e.timeStamp, e.position);
    _gMode = KotvFsMode.none;
  }

  void _onSwipePointerMove(PointerMoveEvent e) {
    if (_pointers.containsKey(e.pointer)) {
      _pointers[e.pointer] = e.position;
    }
    if (_gestureLocked) return;

    if (_gMode == KotvFsMode.pinch && _pointers.length >= 2) {
      final pts = _pointers.values.toList();
      final span = (pts[0] - pts[1]).distance.clamp(1.0, 10000.0);
      final next = (_pinchStartScale * span / _pinchSpan0).clamp(1.0, 5.0);
      _pinchFocal = Offset((pts[0].dx + pts[1].dx) / 2, (pts[0].dy + pts[1].dy) / 2);
      setState(() => _pinchScale = next);
      return;
    }

    if (e.pointer != _swipePointer || _swipeDownAt == null) return;
    if (_holdingSpeed) return;
    _swipeVelocity?.addPosition(e.timeStamp, e.position);
    final total = e.position - _swipeDownAt!;
    final size = MediaQuery.sizeOf(context);

    if (_gMode == KotvFsMode.none) {
      if (total.distance < kTouchSlop) return;
      final mode = KotvFsGesture.classifyDrag(
        total: total,
        downX: _swipeDownAt!.dx,
        width: size.width,
        canEp: _canSwipeEps,
        television: !_playerGestures,
      );
      _beginDragMode(mode, total);
      return;
    }

    switch (_gMode) {
      case KotvFsMode.seek:
        final ms = (total.dx * KotvFsGesture.seekMsPerPx).round();
        setState(() {
          _seekPreviewBase ??= widget.playback.position;
          _seekPreviewDelta = Duration(milliseconds: ms);
        });
        break;
      case KotvFsMode.bright:
      case KotvFsMode.volume:
        _applySideDrag(-total.dy, size.height);
        break;
      case KotvFsMode.ep:
        if (_pointerSwiping) _applySwipeDelta(e.delta.dy);
        break;
      case KotvFsMode.none:
      case KotvFsMode.channel:
      case KotvFsMode.pinch:
        break;
    }
  }

  void _endGesturePointer(int pointer, {required bool cancelled, Offset? upPos, Duration? timeStamp}) {
    _pointers.remove(pointer);
    if (_gMode == KotvFsMode.pinch) {
      if (_pointers.length < 2) {
        _gMode = KotvFsMode.none;
      }
      return;
    }
    if (pointer != _swipePointer) return;
    if (timeStamp != null && upPos != null) {
      _swipeVelocity?.addPosition(timeStamp, upPos);
    }
    final swiping = _pointerSwiping;
    final downAt = _swipeDownAt;
    final mode = _gMode;
    final velocity = _swipeVelocity?.getVelocity().pixelsPerSecond.dy ?? 0;
    final suppressTap = _suppressTapAfterHold || _holdingSpeed;
    _swipePointer = null;
    _swipeDownAt = null;
    _swipeVelocity = null;
    _pointerSwiping = false;
    _gMode = KotvFsMode.none;
    if (_holdingSpeed) _stopHoldSpeed();
    if (suppressTap) {
      _suppressTapAfterHold = false;
      _clearSideHud();
      if (_seekPreviewBase != null) _cancelSeekPreview();
      return;
    }
    switch (mode) {
      case KotvFsMode.seek:
        if (!cancelled && _seekPreviewBase != null) {
          _commitSeekPreview();
        } else {
          _cancelSeekPreview();
        }
        break;
      case KotvFsMode.bright:
      case KotvFsMode.volume:
        _clearSideHud();
        break;
      case KotvFsMode.ep:
        if (swiping) {
          if (cancelled) {
            unawaited(_animateSwipeTo(0));
          } else {
            _commitSwipe(velocity);
          }
        } else if (_dragDy.abs() > 0.5) {
          unawaited(_animateSwipeTo(0));
        }
        break;
      case KotvFsMode.none:
        if (!cancelled) {
          final dist = downAt == null || upPos == null ? 0.0 : (upPos - downAt).distance;
          if (dist < kTouchSlop) _handleVideoTap();
        }
        break;
      case KotvFsMode.channel:
      case KotvFsMode.pinch:
        break;
    }
  }

  void _onSwipePointerUp(PointerUpEvent e) {
    _endGesturePointer(e.pointer, cancelled: false, upPos: e.position, timeStamp: e.timeStamp);
  }

  void _onSwipePointerCancel(PointerCancelEvent e) {
    _endGesturePointer(e.pointer, cancelled: true);
  }

  Future<void> _animateSwipeTo(double target, {VoidCallback? onDone}) async {
    final from = _dragDy;
    _swipeTween = Tween<double>(begin: from, end: target).animate(
      CurvedAnimation(parent: _swipeAnim, curve: Curves.easeOutCubic),
    );
    _swipeAnim.duration = Duration(milliseconds: (180 + (from - target).abs() / 6).round().clamp(180, 360));
    _swipeAnim.reset();
    await _swipeAnim.forward();
    if (!mounted) return;
    // 切集时直接落到新页 offset=0，避免黑帧闪一下
    setState(() {
      _setDragDy(0);
      _dragging = false;
    });
    onDone?.call();
  }

  void _commitSwipe(double velocityDy) {
    if (!_canSwipeEps) {
      setState(() {
        _setDragDy(0);
        _dragging = false;
      });
      return;
    }
    final now = DateTime.now();
    if (_lastSwipeAt != null && now.difference(_lastSwipeAt!) < const Duration(milliseconds: 450)) {
      unawaited(_animateSwipeTo(0));
      return;
    }
    final h = MediaQuery.sizeOf(context).height;
    final v = velocityDy;
    final commitNext = (v < -420 || _dragDy < -h * 0.18) && _epIdx + 1 < widget.episodes.length;
    final commitPrev = (v > 420 || _dragDy > h * 0.18) && _epIdx > 0;
    // 上滑 = 下一集；下滑 = 上一集
    if (commitNext) {
      _lastSwipeAt = now;
      final next = _epIdx + 1;
      final name = next < widget.episodes.length ? widget.episodes[next] : '';
      _flashSwipeHint(name.isEmpty ? '下一集' : '下一集 · $name');
      unawaited(_animateSwipeTo(-h, onDone: () => _goNext(didAnimate: true)));
    } else if (commitPrev) {
      _lastSwipeAt = now;
      final prev = _epIdx - 1;
      final name = prev >= 0 ? widget.episodes[prev] : '';
      _flashSwipeHint(name.isEmpty ? '上一集' : '上一集 · $name');
      unawaited(_animateSwipeTo(h, onDone: _goPrev));
    } else {
      unawaited(_animateSwipeTo(0));
    }
  }

  Widget _swipePeek({required String label, required Alignment align}) {
    return ColoredBox(
      color: Colors.black,
      child: Align(
        alignment: align,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withOpacity(0.88),
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }

  void _seekByRemote(Duration delta) {
    final next = widget.playback.position + delta;
    widget.playback.seek(next.isNegative ? Duration.zero : next);
  }

  static const _seekStep = Duration(seconds: 10);

  Duration get _seekPreviewTarget {
    final base = _seekPreviewBase ?? widget.playback.position;
    final dur = widget.playback.duration;
    var t = base + _seekPreviewDelta;
    if (t.isNegative) t = Duration.zero;
    if (boundedMediaDuration(dur) && t > dur) t = dur;
    return t;
  }

  void _nudgeSeekPreview(Duration step) {
    _seekPreviewBase ??= widget.playback.position;
    setState(() => _seekPreviewDelta += step);
  }

  void _commitSeekPreview() {
    if (_seekPreviewBase == null) return;
    final target = _seekPreviewTarget;
    _seekPreviewBase = null;
    _seekPreviewDelta = Duration.zero;
    if (mounted) setState(() {});
    widget.playback.seek(target);
  }

  void _cancelSeekPreview() {
    if (_seekPreviewBase == null) return;
    _seekPreviewBase = null;
    _seekPreviewDelta = Duration.zero;
    if (mounted) setState(() {});
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final isDown = event is KeyDownEvent;
    final isRepeat = event is KeyRepeatEvent;
    final isUp = event is KeyUpEvent;
    final key = event.logicalKey;

    if (isDown && kotvIsBackKey(key)) {
      final back = detailImmersiveBack;
      if (back != null) {
        unawaited(back());
      } else if (!_dismissOneLayer()) {
        unawaited(_exitFullscreen());
      }
      return KeyEventResult.handled;
    }
    if (isUp && kotvIsBackKey(key)) return KeyEventResult.ignored;

    if (_gestureLocked) {
      if (_holdingSpeed || _remoteHoldSpeed) {
        _remoteHoldSpeed = false;
        _stopHoldSpeed();
      }
      return KeyEventResult.handled;
    }

    // 栏隐：上键抬起 — 曾倍速则只恢复，不亮栏；短按抬起才亮栏。
    if (isUp && !_showChrome && !_epOpen && kotvIsUpKey(key)) {
      if (_remoteHoldSpeed || _holdingSpeed) {
        _remoteHoldSpeed = false;
        _stopHoldSpeed();
        return KeyEventResult.handled;
      }
      _cancelSeekPreview();
      _showChromeAndFocusPlay();
      return KeyEventResult.handled;
    }

    // 栏隐左右键：抬键提交预览 seek（保持栏隐）。
    if (isUp && !_showChrome && !_epOpen && (kotvIsLeftKey(key) || kotvIsRightKey(key) || kotvIsMediaRewind(key) || kotvIsMediaFastForward(key))) {
      if (_seekPreviewBase != null) {
        _commitSeekPreview();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    if (!isDown && !isRepeat) return KeyEventResult.ignored;

    // 有底栏/选集：方向键交给 TvFocus；快退/快进才 seek（勿抢横移）。
    if (_showChrome || _epOpen) {
      if (isDown && kotvIsMenuKey(key)) {
        _toggleEpisodes();
        return KeyEventResult.handled;
      }
      if (isDown && (kotvIsSettingsKey(key) || key == LogicalKeyboardKey.keyE)) {
        _toggleEpisodes();
        return KeyEventResult.handled;
      }
      if (!_epOpen && kotvIsMediaRewind(key)) {
        _seekByRemote(const Duration(seconds: -10));
        _bumpChrome(); // 栏已显仅续命
        return KeyEventResult.handled;
      }
      if (!_epOpen && kotvIsMediaFastForward(key)) {
        _seekByRemote(const Duration(seconds: 10));
        _bumpChrome();
        return KeyEventResult.handled;
      }
      if (isDown &&
          (kotvIsEnterKey(key) ||
              kotvIsMediaPlayPause(key) ||
              kotvIsDpadNavKey(key))) {
        if (kotvPrimaryIsEmptyOr(node)) {
          _chromeKey.currentState?.restoreRemoteFocus();
          _bumpChrome(intentional: true);
          return KeyEventResult.handled;
        }
        _bumpChrome(intentional: true);
        return KeyEventResult.ignored;
      }
      return KeyEventResult.ignored;
    }

    // 缓冲网速层可见时，左右键不要快进快退，先亮底栏再在控件间移动。
    if (widget.playback.stalling &&
        (isDown || isRepeat) &&
        (kotvIsLeftKey(key) || kotvIsRightKey(key) || kotvIsUpKey(key) || kotvIsDownKey(key))) {
      _showChromeAndFocusPlay();
      return KeyEventResult.handled;
    }

    // —— 控件全隐：一键一义 ——
    // OK/播停 → 真播停（可短暂亮栏）；菜单 → 选集；设置/E → 选集；左右 → seek；上长按 → 倍速；下 → 亮控件。
    if (isDown && (kotvIsEnterKey(key) || kotvIsMediaPlayPause(key))) {
      unawaited(widget.playback.playOrPause());
      _showChromeAndFocusPlay();
      return KeyEventResult.handled;
    }
    if (isDown && kotvIsMenuKey(key)) {
      _toggleEpisodes();
      return KeyEventResult.handled;
    }
    if (isDown && (kotvIsSettingsKey(key) || key == LogicalKeyboardKey.keyE)) {
      _toggleEpisodes();
      return KeyEventResult.handled;
    }
    if (kotvIsLeftKey(key) || kotvIsMediaRewind(key)) {
      _nudgeSeekPreview(-_seekStep);
      return KeyEventResult.handled;
    }
    if (kotvIsRightKey(key) || kotvIsMediaFastForward(key)) {
      _nudgeSeekPreview(_seekStep);
      return KeyEventResult.handled;
    }
    // 上键：KeyRepeat 进临时倍速；短按亮栏在 KeyUp。
    if (kotvIsUpKey(key)) {
      if (isRepeat || (isDown && _remoteHoldSpeed)) {
        if (!_holdingSpeed) {
          _remoteHoldSpeed = true;
          _cancelSeekPreview();
          _startHoldSpeed();
        }
        return KeyEventResult.handled;
      }
      if (isDown) return KeyEventResult.handled; // 等 KeyUp 判定短按
      return KeyEventResult.ignored;
    }
    if (isDown && kotvIsDownKey(key)) {
      _cancelSeekPreview();
      _showChromeAndFocusPlay();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _showChromeAndFocusPlay() {
    _bumpChrome(intentional: true);
    _chromeKey.currentState?.restoreRemoteFocus();
  }

  void _onHover(PointerHoverEvent e, BoxConstraints c) {
    // 仅从窗外进入时取消离窗定时器；窗内移动不取消面板 onExit 的隐藏计时。
    if (!_pointerIn) {
      _pointerIn = true;
      _chromeKey.currentState?.cancelScheduledCloseEpisodes();
    }
    final onRight = e.localPosition.dx >= c.maxWidth - KotvFsGesture.edgeIgnore;
    if (onRight && !_epOpen && widget.episodes.isNotEmpty) {
      _chromeKey.currentState?.openEpisodes();
      setState(() {});
    }
    // 桌面：栏隐时移入也亮栏（Win HWND 压在画面上时否则播控不可达）。
    // 移动端仍被动续命，避免滑动误亮栏。
    _bumpChrome(intentional: kotvIsDesktop());
  }

  void _onPointerExit() {
    _pointerIn = false;
    // 离窗：清栏上 hold，再计时关选集与底栏。
    _chromeKey.currentState?.releasePointerHold();
    _chromeKey.currentState?.scheduleCloseEpisodes();
    _schedulePlayingHide();
  }

  void _onEpisodesClosed() {
    if (!mounted) return;
    // 关右侧选集后保持沉浸；hover 不可立刻回弹，须点画面/遥控才亮。
    _stayChromeImmersive(untilPlay: false);
  }

  Widget _buildVideo() {
    if (widget.externalVideo) {
      // 画面在父级 Stack；此处留空透出下层 Texture。
      return const SizedBox.expand();
    }
    Widget video = widget.videoChild;
    final ratio = _aspect.ratio;
    // Android MPV：比例在原生 setAspect，勿再套 AspectRatio。
    final skipFlutterRatio = kotvIsAndroid() && widget.playback is NativeMpvPlayback;
    if (!skipFlutterRatio && ratio != null && ratio > 0) {
      // 勿用 LayoutBuilder+Center+SizedBox，易与 Video 叠出无限 layout。
      video = ColoredBox(
        color: Colors.black,
        child: Center(
          child: AspectRatio(aspectRatio: ratio, child: video),
        ),
      );
    }

    if (!_ambientOn) return video;
    // 氛围：背后模糊洗色 + 视频略压暗，形成影院氛围
    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                const Color(0xFF141210).withOpacity(0.98),
                const Color(0xFF0C1218).withOpacity(0.98),
                const Color(0xFF18140E).withOpacity(0.98),
              ],
            ),
          ),
        ),
        BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
          child: const ColoredBox(color: Color(0x33000000)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 36),
          child: DecoratedBox(
            decoration: BoxDecoration(
              boxShadow: [
                BoxShadow(color: Colors.black.withOpacity(0.45), blurRadius: 40, offset: const Offset(0, 12)),
              ],
            ),
            child: video,
          ),
        ),
      ],
    );
  }


  Widget _forceLandscapeChip(BoxConstraints c) {
    final screen = Size(c.maxWidth, c.maxHeight);
    final videoRect = kotvVideoContainRect(
      screen: screen,
      videoWidth: widget.playback.width,
      videoHeight: widget.playback.height,
    );
    final top = (videoRect.bottom + 12).clamp(0.0, (c.maxHeight - 52).clamp(0.0, c.maxHeight));
    return Positioned(
      left: 0,
      right: 0,
      top: top,
      child: Align(
        alignment: Alignment.topCenter,
        child: TvFocus(
          onPressed: () => unawaited(_forceLandscape()),
          borderRadius: 24,
          child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => unawaited(_forceLandscape()),
            canRequestFocus: false,
            borderRadius: BorderRadius.circular(24),
            child: Ink(
              decoration: BoxDecoration(
                color: const Color(0xE6121212),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.white.withOpacity(0.28)),
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: LayoutScale.dp(context, 18),
                  vertical: LayoutScale.dp(context, 10),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.screen_rotation_rounded,
                      color: Colors.white,
                      size: LayoutScale.dp(context, 20),
                    ),
                    SizedBox(width: LayoutScale.dp(context, 8)),
                    const Text(
                      '全屏观看',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          ),
        ),
      ),
    );
  }

  Widget _fullscreenChrome() {
    // Win7：mpv HWND 盖住 Flutter；顶底栏/选集/弹幕由进程内原生壳承接（与 macOS/Win8+ Flutter chrome 隔离）。
    if (KotvWinChrome.isNeeded) return const SizedBox.shrink();
    return VodFullscreenChrome(
      key: _chromeKey,
      player: widget.playback,
      title: _title,
      visible: _showChrome && !_gestureLocked && !_dragging && _dragDy.abs() < 4,
      onToggleVisible: _bumpChrome,
      onExit: () => unawaited(_exitFullscreen()),
      onBump: _bumpChrome,
      onHoldChanged: _onChromeHoldChanged,
      onEpisodesAutoClosed: _onEpisodesClosed,
      episodes: widget.episodes,
      epIdx: _epIdx,
      aspect: _aspect,
      onAspectChanged: (a) {
        setState(() {
          _aspect = a;
          _pinchScale = 1.0;
        });
        unawaited(widget.playback.setVideoScale(a.key));
        widget.onAspectChanged?.call(a);
        _flashSwipeHint('比例：${a.key == 'default' ? '适应' : a.key == 'fill' ? '拉伸' : a.key == 'zoom' ? 'Zoom' : a.key}');
      },
      locked: _gestureLocked,
      onLockChanged: _gestureLockUi ? _setGestureLocked : null,
      playUrl: widget.playUrl,
      decodeMode: _decodeMode,
      renderMode: _renderMode,
      onDecodeChanged: (m) => unawaited(_onDecode(m)),
      onRenderChanged: (m) => unawaited(_onRender(m)),
      onPersistSetting: widget.onPersistSetting,
      onLoadSettings: widget.onLoadSettings,
      onPlayerStatus: widget.onPlayerStatus,
      onExternalPlayer: widget.onExternalPlayer,
      onToggleKeep: widget.onToggleKeep,
      keepLabel: widget.keepLabel,
      onParse: widget.onParse,
      onRefresh: widget.onRefresh,
      onCast: widget.onCast,
      onMini: widget.onMini,
      // 竖屏用「全屏观看」；仅锁横屏后顶栏出「竖屏」以便切回。
      onRotate: _showTopPortraitRotate ? () => unawaited(_lockPortraitMode()) : null,
      rotateLabel: _showTopPortraitRotate ? '竖屏' : null,
      danmakuSources: widget.danmakuSources,
      danmakuSourceIdx: widget.danmakuSourceIdx,
      onDanmakuSourceChanged: widget.onDanmakuSourceChanged,
      onDanmakuSearch: widget.onDanmakuSearch,
      onDanmakuSettingsChanged: widget.onDanmakuSettingsChanged,
      ambientOn: _ambientOn,
      onAmbientChanged: (v) {
        setState(() => _ambientOn = v);
        widget.onAmbientChanged?.call(v);
      },
      onRepeatOneChanged: widget.onRepeatOneChanged,
      stableVolumeOn: widget.stableVolumeOn,
      onAssrtSearch: widget.onAssrtSearch,
      offsetId: widget.offsetId,
      offsetSite: widget.offsetSite,
      openingSec: widget.openingSec,
      endingSec: widget.endingSec,
      onOffsetsChanged: widget.onOffsetsChanged,
      onSelectEp: _selectEp,
      onNext: _goNext,
      onPrev: _goPrev,
      onReplay: () {
        widget.playback.seek(Duration.zero);
        widget.playback.play();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // Win7 全屏 / 铺满窗口：视频与播控、手势、弹幕全在原生 HWND；
    // Flutter 页整页挖空，只留 Focus 收键盘/返回（事件亦经 kotv_win_chrome）。
    if (KotvWinChrome.isNeeded) {
      return Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: const IgnorePointer(child: SizedBox.expand()),
      );
    }
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        // externalVideo：画面在详情 Stack 下层 Positioned；此处必须透明，否则盖成全黑。
        // 换集：桌面销毁再建 Player，Stable 宿主按 [_playUrl] 保活；Android 另有过渡黑盖。
        backgroundColor: widget.externalVideo ? Colors.transparent : Colors.black,
        body: LayoutBuilder(
          builder: (context, c) {
            final ui = LayoutScale.grow(context);
            // 横屏钮由 initState / playback listener 刷新；勿在 build 里登记 postFrame。
            return MouseRegion(
              cursor: _mouseCursor,
              onHover: (e) => _onHover(e, c),
              onExit: (_) => _onPointerExit(),
              child: Stack(
                fit: StackFit.expand,
                clipBehavior: Clip.hardEdge,
                children: [
                  if (_dragDy > 8 && _epIdx > 0)
                    Positioned(
                      left: 0,
                      right: 0,
                      top: _dragDy - c.maxHeight,
                      height: c.maxHeight,
                      child: _swipePeek(
                        label: '上一集 · ${widget.episodes[_epIdx - 1]}',
                        align: Alignment.bottomCenter,
                      ),
                    ),
                  if (_dragDy < -8 && _epIdx + 1 < widget.episodes.length)
                    Positioned(
                      left: 0,
                      right: 0,
                      top: c.maxHeight + _dragDy,
                      height: c.maxHeight,
                      child: _swipePeek(
                        label: '下一集 · ${widget.episodes[_epIdx + 1]}',
                        align: Alignment.topCenter,
                      ),
                    ),
                  // 画面跟手；网速/全屏按钮/控件在外层，避免与 PlatformView 同栈叠影。
                  Positioned(
                    left: 0,
                    right: 0,
                    top: _dragDy,
                    height: c.maxHeight,
                    child: Transform(
                      alignment: Alignment.center,
                      transform: KotvFsGesture.pinchTransform(
                        scale: _pinchScale,
                        focal: _pinchFocal,
                        size: Size(c.maxWidth, c.maxHeight),
                      ),
                      child: Stack(
                      fit: StackFit.expand,
                      clipBehavior: Clip.hardEdge,
                      children: [
                        _buildVideo(),
                        if (!KotvWinChrome.isNeeded)
                        DanmakuOverlay(
                          enabled: _danmakuOn,
                          player: widget.playback,
                          items: widget.danmakuItems,
                          fontSize: widget.danmakuSize,
                          opacity: widget.danmakuOpacity,
                          rows: widget.danmakuRows,
                          maxOnScreen: widget.danmakuMaxOnScreen,
                          scrollAreaRatio: widget.danmakuScrollArea,
                          showScroll: widget.danmakuShowScroll,
                          showTop: widget.danmakuShowTop,
                          showBottom: widget.danmakuShowBottom,
                          showReverse: widget.danmakuShowReverse,
                          showSpecial: widget.danmakuShowSpecial,
                          showPositioned: widget.danmakuShowPositioned,
                          bold: widget.danmakuBold,
                          durationMs: widget.danmakuDurationMs,
                          fixedDurationMs: widget.danmakuFixedDurationMs,
                          lineSpacing: widget.danmakuLineSpacing,
                          strokeMode: widget.danmakuStrokeMode,
                          colorMode: widget.danmakuColorMode,
                          rowsTop: widget.danmakuRowsTop,
                          rowsBottom: widget.danmakuRowsBottom,
                          fontFamily: widget.danmakuFontFamily,
                          scrollGapRatio: widget.danmakuScrollGap,
                          strokeWidth: widget.danmakuStrokeWidth,
                          shadowOpacity: widget.danmakuShadowOpacity,
                          projectionOffsetX: widget.danmakuProjectionOffsetX,
                          projectionOffsetY: widget.danmakuProjectionOffsetY,
                          projectionOpacity: widget.danmakuProjectionOpacity,
                        ),
                      ],
                    ),
                    ),
                  ),
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onLongPressStart: (_) => _startHoldSpeed(),
                      onLongPressEnd: (_) => _stopHoldSpeed(),
                      onLongPressCancel: _stopHoldSpeed,
                      child: Listener(
                        behavior: HitTestBehavior.translucent,
                        onPointerDown: _onSwipePointerDown,
                        onPointerMove: _onSwipePointerMove,
                        onPointerUp: _onSwipePointerUp,
                        onPointerCancel: _onSwipePointerCancel,
                        onPointerSignal: _onPointerSignal,
                        onPointerPanZoomUpdate: _onPointerPanZoomUpdate,
                      ),
                    ),
                  ),
                  if (_holdSpeedHint != null)
                    IgnorePointer(
                      child: Center(
                        child: Container(
                          padding: EdgeInsets.symmetric(horizontal: 18 * ui, vertical: 10 * ui),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.62),
                            borderRadius: BorderRadius.circular(22 * ui),
                          ),
                          child: Text(
                            _holdSpeedHint!,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (_sideGesture != null)
                    IgnorePointer(
                      child: Center(
                        child: Container(
                          padding: EdgeInsets.symmetric(horizontal: 20 * ui, vertical: 12 * ui),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.62),
                            borderRadius: BorderRadius.circular(16 * ui),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _sideGesture!.kind == 'bright'
                                    ? Icons.brightness_6_rounded
                                    : Icons.volume_up_rounded,
                                color: Colors.white,
                                size: 22 * ui,
                              ),
                              SizedBox(width: 10 * ui),
                              Text(
                                '${_sideGesture!.percent.round()}%',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 16 * ui,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (_gestureLocked)
                    Positioned(
                      right: 16 * ui,
                      bottom: 28 * ui,
                      child: Material(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(24 * ui),
                        child: InkWell(
                          onTap: () => _setGestureLocked(false),
                          borderRadius: BorderRadius.circular(24 * ui),
                          child: Padding(
                            padding: EdgeInsets.all(12 * ui),
                            child: Icon(Icons.lock_open_rounded, color: Colors.white, size: 26 * ui),
                          ),
                        ),
                      ),
                    ),
                  // Win7：缓冲/解析提示由原生壳承接，勿在 Flutter 全屏层再画转圈。
                  if (widget.playUrl.isNotEmpty && !KotvWinChrome.isNeeded)
                    KotvBufferingOverlay(player: widget.playback),
                  if (_showForceLandscape && !_dragging && !_gestureLocked && _dragDy.abs() < 4)
                    _forceLandscapeChip(c),
                  _fullscreenChrome(),
                  if (_seekPreviewBase != null)
                    IgnorePointer(
                      child: Center(
                        child: Container(
                          padding: EdgeInsets.symmetric(horizontal: 22 * ui, vertical: 14 * ui),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.72),
                            borderRadius: BorderRadius.circular(16 * ui),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _seekPreviewDelta >= Duration.zero
                                    ? Icons.fast_forward_rounded
                                    : Icons.fast_rewind_rounded,
                                color: Colors.white,
                                size: 28 * ui,
                              ),
                              SizedBox(width: 12 * ui),
                              Text(
                                '${fmtBoundedPlayerTime(_seekPreviewTarget)} / ${fmtBoundedPlayerTime(widget.playback.duration)}',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 18 * ui,
                                  fontWeight: FontWeight.w700,
                                  fontFeatures: const [FontFeature.tabularFigures()],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    )
                  else if (_swipeHint != null)
                    IgnorePointer(
                      child: Center(
                        child: AnimatedOpacity(
                          opacity: 1,
                          duration: const Duration(milliseconds: 120),
                          child: Container(
                            padding: EdgeInsets.symmetric(horizontal: 18 * ui, vertical: 10 * ui),
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.62),
                              borderRadius: BorderRadius.circular(22 * ui),
                            ),
                            child: Text(
                              _swipeHint!,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
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
}
