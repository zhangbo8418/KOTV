import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../player/danmaku_layer.dart';
import '../player/exo_playback.dart';
import '../player/fullscreen_mode.dart';
import '../player/fvp_playback.dart';
import '../player/html_playback.dart';
import '../player/art_playback.dart';
import '../player/xg_playback.dart';
import '../player/zw_playback.dart';
import '../player/kotv_playback.dart';
import '../player/kotv_platform.dart';
import '../nav/kotv_page.dart';
import '../widgets/buffering_overlay.dart';
import '../widgets/vod_player_chrome.dart';

/// 详情页全屏：MPV / FVP / Exo 共用同一套顶底控件。
class DetailFullscreenPage extends StatefulWidget {
  const DetailFullscreenPage({
    super.key,
    required this.playback,
    required this.vodName,
    required this.title,
    this.episodes = const [],
    this.epIdx = -1,
    this.onSelectEp,
    this.onNext,
    this.onPrev,
    this.playUrl = '',
    this.decodeMode = 'auto',
    this.renderMode = 'surface',
    this.aspect = const AspectSpec(key: 'default', fit: BoxFit.contain),
    this.onDecodeChanged,
    this.onPersistSetting,
    this.onPlayerStatus,
    this.onExternalPlayer,
    this.onToggleKeep,
    this.keepLabel = '收藏',
    this.onParse,
    this.onRefresh,
    this.onCast,
    this.onMini,
    this.danmakuOn = false,
    this.onDanmakuChanged,
    this.danmakuItems = const [],
    this.ambientOn = false,
    this.onAmbientChanged,
    this.stableVolumeOn = false,
    this.offsetId = '',
    this.offsetSite = '',
    this.openingSec = 0,
    this.endingSec = 0,
    this.onOffsetsChanged,
    this.desktopFullscreen = KotvDesktopFullscreenKind.window,
  });

  final KotvPlayback playback;
  final String vodName;
  final String title;
  final List<String> episodes;
  final int epIdx;
  final void Function(int idx)? onSelectEp;
  final VoidCallback? onNext;
  final VoidCallback? onPrev;
  final String playUrl;
  final String decodeMode;
  final String renderMode;
  final AspectSpec aspect;
  final ValueChanged<String>? onDecodeChanged;
  final Future<void> Function(String key, String value)? onPersistSetting;
  final Future<Map<String, dynamic>> Function()? onPlayerStatus;
  final Future<void> Function(String playerVal)? onExternalPlayer;
  final Future<String> Function()? onToggleKeep;
  final String keepLabel;
  final VoidCallback? onParse;
  final VoidCallback? onRefresh;
  final VoidCallback? onCast;
  final VoidCallback? onMini;
  final bool danmakuOn;
  final ValueChanged<bool>? onDanmakuChanged;
  final List<DanmakuItem> danmakuItems;
  final bool ambientOn;
  final ValueChanged<bool>? onAmbientChanged;
  final bool stableVolumeOn;
  final String offsetId;
  final String offsetSite;
  final int openingSec;
  final int endingSec;
  final void Function(int openingSec, int endingSec)? onOffsetsChanged;
  /// PC：铺满当前窗口 / 占满整块屏幕；移动端忽略。
  final KotvDesktopFullscreenKind desktopFullscreen;

  @override
  State<DetailFullscreenPage> createState() => DetailFullscreenPageState();
}

class DetailFullscreenPageState extends State<DetailFullscreenPage>
    with SingleTickerProviderStateMixin {
  bool _showChrome = true;
  MouseCursor _mouseCursor = SystemMouseCursors.basic;
  bool _pointerIn = false;
  late AspectSpec _aspect = widget.aspect;
  late String _decodeMode = widget.decodeMode;
  late String _renderMode = widget.renderMode;
  late int _epIdx = widget.epIdx;
  late bool _danmakuOn = widget.danmakuOn;
  late bool _ambientOn = widget.ambientOn;
  Timer? _hideTimer;
  StreamSubscription<Duration>? _posSub;
  Duration _pos = Duration.zero;
  final GlobalKey<VodFullscreenChromeState> _chromeKey = GlobalKey<VodFullscreenChromeState>();

  /// 抖音式上下滑切集：跟手位移 + 松手吸附/切集
  double _dragDy = 0;
  bool _dragging = false;
  late final AnimationController _swipeAnim;
  Animation<double>? _swipeTween;
  String? _swipeHint;
  Timer? _hintTimer;
  DateTime? _lastSwipeAt;
  bool _forcedLandscape = false;
  bool _showForceLandscape = false;

  String get _title {
    if (_epIdx >= 0 && _epIdx < widget.episodes.length) {
      return '${widget.vodName} · ${widget.episodes[_epIdx]}';
    }
    return widget.vodName.isNotEmpty ? widget.vodName : widget.title;
  }

  @override
  void initState() {
    super.initState();
    _swipeAnim = AnimationController(vsync: this, duration: const Duration(milliseconds: 280))
      ..addListener(() {
        final t = _swipeTween;
        if (t == null || !mounted) return;
        setState(() => _dragDy = t.value);
      });
    _pos = widget.playback.position;
    _posSub = widget.playback.positionStream.listen((d) {
      if (!mounted) return;
      // 时间轴只显示到秒：MPV 每帧都推位置，逐条 setState 会整页重建到掉帧。
      if (d.inSeconds == _pos.inSeconds) return;
      setState(() => _pos = d);
    });
    widget.playback.addListener(_onPlaybackChanged);
    // 自动下一集由详情页负责；此处勿再听 completed（会与父页抢跳导致连跳）
    unawaited(kotvEnterSystemFullscreen(widget.desktopFullscreen));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _refreshForceLandscapeBtn();
        if (widget.playback.playing) {
          _schedulePlayingHide();
        } else {
          _setChrome(show: true, hideCursor: false);
        }
      }
    });
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
      widget.playback.addListener(_onPlaybackChanged);
      _posSub?.cancel();
      _pos = widget.playback.position;
      _posSub = widget.playback.positionStream.listen((d) {
        if (!mounted) return;
        if (d.inSeconds == _pos.inSeconds) return;
        setState(() => _pos = d);
      });
      _refreshForceLandscapeBtn();
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _hintTimer?.cancel();
    _swipeAnim.dispose();
    _posSub?.cancel();
    widget.playback.removeListener(_onPlaybackChanged);
    unawaited(_restoreChrome());
    super.dispose();
  }

  void _onPlaybackChanged() {
    _refreshForceLandscapeBtn();
    if (!widget.playback.playing) {
      _hideTimer?.cancel();
      _setChrome(show: true, hideCursor: false);
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
  }

  void _schedulePlayingHide() {
    _hideTimer?.cancel();
    if (!widget.playback.playing) return;
    _hideTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted || !widget.playback.playing || _epOpen) return;
      _setChrome(show: false, hideCursor: _hideCursorWhenIdle);
    });
  }

  void _bumpChrome() {
    _setChrome(show: true, hideCursor: false);
    _schedulePlayingHide();
  }

  /// 点画面：只显隐控件，不播停。控件已显示则再点一次收起。
  void _onVideoTap() {
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
    _bumpChrome();
  }

  void _refreshForceLandscapeBtn() {
    if (!mounted || _forcedLandscape) {
      if (_showForceLandscape) setState(() => _showForceLandscape = false);
      return;
    }
    final show = kotvShouldShowForceLandscape(
      screen: MediaQuery.sizeOf(context),
      videoWidth: widget.playback.width,
      videoHeight: widget.playback.height,
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
  }

  Future<void> _restoreChrome() async {
    await kotvExitSystemFullscreen(
      wasDisplayFullscreen: widget.desktopFullscreen == KotvDesktopFullscreenKind.display,
    );
  }

  Future<void> _exitFullscreen() async {
    await _restoreChrome();
    if (mounted) Navigator.of(context).maybePop();
  }

  bool get _epOpen => _chromeKey.currentState?.epOpen ?? false;

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
    setState(() => _renderMode = mode);
    await widget.playback.setRenderMode(mode);
  }

  void _goNext() {
    if (_epIdx + 1 >= widget.episodes.length) {
      _flashSwipeHint('已是最后一集');
      return;
    }
    widget.onNext?.call();
    final next = _epIdx + 1;
    if (next < widget.episodes.length) {
      setState(() => _epIdx = next);
    }
    _bumpChrome();
  }

  /// 播完自动下一集：与上滑手势同一套跟手/吸附动画（抖音式）。
  Future<bool> animateAutoNext() async {
    if (!mounted) return false;
    if (_epIdx + 1 >= widget.episodes.length) return false;
    if (_swipeAnim.isAnimating || _dragging) return false;
    final h = MediaQuery.sizeOf(context).height;
    if (h <= 0) return false;
    final next = _epIdx + 1;
    final name = widget.episodes[next];
    _flashSwipeHint(name.isEmpty ? '下一集' : '下一集 · $name');
    _swipeAnim.stop();
    _swipeTween = null;
    setState(() {
      _dragging = true;
      _dragDy = 0;
    });
    await _animateSwipeTo(-h);
    return mounted;
  }

  void _goPrev() {
    if (_epIdx <= 0) {
      _flashSwipeHint('已是第一集');
      return;
    }
    widget.onPrev?.call();
    final prev = _epIdx - 1;
    if (prev >= 0) {
      setState(() => _epIdx = prev);
    }
    _bumpChrome();
  }

  void _selectEp(int i) {
    widget.onSelectEp?.call(i);
    setState(() => _epIdx = i);
    _bumpChrome();
  }

  bool get _canSwipeEps => !_epOpen && widget.episodes.length > 1;

  void _onVerticalDragStart(DragStartDetails _) {
    if (!_canSwipeEps) return;
    _swipeAnim.stop();
    _swipeTween = null;
    setState(() {
      _dragging = true;
      _dragDy = 0;
    });
  }

  void _onVerticalDragUpdate(DragUpdateDetails d) {
    if (!_canSwipeEps || !_dragging) return;
    final h = MediaQuery.sizeOf(context).height;
    var next = _dragDy + d.delta.dy;
    // 到顶/到底橡胶阻尼
    if ((_epIdx <= 0 && next > 0) || (_epIdx + 1 >= widget.episodes.length && next < 0)) {
      next = next * 0.35;
    }
    next = next.clamp(-h * 0.92, h * 0.92);
    setState(() => _dragDy = next);
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
      _dragDy = 0;
      _dragging = false;
    });
    onDone?.call();
  }

  void _onVerticalDragEnd(DragEndDetails d) {
    if (!_canSwipeEps) {
      setState(() {
        _dragDy = 0;
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
    final v = d.primaryVelocity ?? 0;
    final commitNext = (v < -420 || _dragDy < -h * 0.18) && _epIdx + 1 < widget.episodes.length;
    final commitPrev = (v > 420 || _dragDy > h * 0.18) && _epIdx > 0;
    // 上滑 = 下一集（抖音同款）；下滑 = 上一集
    if (commitNext) {
      _lastSwipeAt = now;
      final next = _epIdx + 1;
      final name = next < widget.episodes.length ? widget.episodes[next] : '';
      _flashSwipeHint(name.isEmpty ? '下一集' : '下一集 · $name');
      unawaited(_animateSwipeTo(-h, onDone: _goNext));
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

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.goBack) {
      if (_epOpen) {
        _chromeKey.currentState?.closeEpisodes();
        setState(() {});
        return KeyEventResult.handled;
      }
      unawaited(_exitFullscreen());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.space || key == LogicalKeyboardKey.mediaPlayPause) {
      widget.playback.playOrPause();
      _bumpChrome();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.mediaRewind) {
      final p = widget.playback.position - const Duration(seconds: 10);
      widget.playback.seek(p.isNegative ? Duration.zero : p);
      _bumpChrome();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.mediaFastForward) {
      widget.playback.seek(widget.playback.position + const Duration(seconds: 10));
      _bumpChrome();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _goPrev();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _goNext();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyE || key == LogicalKeyboardKey.keyM) {
      _chromeKey.currentState?.openEpisodes();
      setState(() {});
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _onHover(PointerHoverEvent e, BoxConstraints c) {
    _pointerIn = true;
    final onRight = e.localPosition.dx >= c.maxWidth - 24;
    if (onRight && !_epOpen && widget.episodes.isNotEmpty) {
      _chromeKey.currentState?.openEpisodes();
      setState(() {});
    }
    _bumpChrome();
  }

  void _onPointerExit() {
    _pointerIn = false;
    _schedulePlayingHide();
  }

  Widget _buildVideo() {
    final pb = widget.playback;
    Widget video;
    if (pb is MediaKitPlayback) {
      final mk = Video(
        controller: pb.controller,
        controls: NoVideoControls,
        fit: _aspect.fit,
        wakelock: false,
      );
      final ratio = _aspect.ratio;
      if (ratio == null || ratio <= 0) {
        video = mk;
      } else {
        video = LayoutBuilder(
          builder: (context, c) {
            var w = c.maxWidth;
            var h = w / ratio;
            if (h > c.maxHeight) {
              h = c.maxHeight;
              w = h * ratio;
            }
            return Center(child: SizedBox(width: w, height: h, child: mk));
          },
        );
      }
    } else if (pb is ExoPlayback) {
      video = pb.buildView(fit: _aspect.fit);
    } else if (pb is FvpPlayback) {
      video = pb.buildView(fit: _aspect.fit);
    } else if (pb is HtmlPlayback) {
      video = pb.buildView(fit: _aspect.fit);
    } else if (pb is ArtPlayback) {
      video = pb.buildView(fit: _aspect.fit);
    } else if (pb is XgPlayback) {
      video = pb.buildView(fit: _aspect.fit);
    } else if (pb is ZwPlayback) {
      video = pb.buildView(fit: _aspect.fit);
    } else {
      video = const ColoredBox(color: Colors.black);
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

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: LayoutBuilder(
          builder: (context, c) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _refreshForceLandscapeBtn();
            });
            return MouseRegion(
              cursor: _mouseCursor,
              onHover: (e) => _onHover(e, c),
              onExit: (_) => _onPointerExit(),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // 下滑露出上一集预览（从上方跟入）
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
                  // 上滑露出下一集预览（从下方跟入）
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
                  // SurfaceView 吃不到 Transform；未跟手时不要套平移层，否则全屏会黑、点一下才闪一帧。
                  Builder(
                    builder: (context) {
                      final videoStack = Stack(
                        fit: StackFit.expand,
                        children: [
                          _buildVideo(),
                          // 盖在 SurfaceView 上面：控件收起时也能上下滑换集；点按只出控件不暂停。
                          Positioned.fill(
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: _onVideoTap,
                              onSecondaryTap: () => kotvHandleAppBack?.call(),
                              onVerticalDragStart: _canSwipeEps ? _onVerticalDragStart : null,
                              onVerticalDragUpdate: _canSwipeEps ? _onVerticalDragUpdate : null,
                              onVerticalDragEnd: _canSwipeEps ? _onVerticalDragEnd : null,
                            ),
                          ),
                          DanmakuOverlay(
                            enabled: _danmakuOn,
                            position: _pos,
                            items: widget.danmakuItems,
                          ),
                          if (widget.playUrl.isNotEmpty)
                            KotvBufferingOverlay(player: widget.playback),
                          if (_showForceLandscape)
                            Builder(
                              builder: (context) {
                                final screen = Size(c.maxWidth, c.maxHeight);
                                final videoRect = kotvVideoContainRect(
                                  screen: screen,
                                  videoWidth: widget.playback.width,
                                  videoHeight: widget.playback.height,
                                );
                                final top = videoRect.bottom + 12;
                                return Positioned(
                                  left: 0,
                                  right: 0,
                                  top: top.clamp(0.0, (c.maxHeight - 52).clamp(0.0, c.maxHeight)),
                                  child: Align(
                                    alignment: Alignment.topCenter,
                                    child: Material(
                                      color: Colors.transparent,
                                      child: InkWell(
                                        onTap: () => unawaited(_forceLandscape()),
                                        borderRadius: BorderRadius.circular(24),
                                        child: Ink(
                                          decoration: BoxDecoration(
                                            color: Colors.black.withOpacity(0.55),
                                            borderRadius: BorderRadius.circular(24),
                                            border: Border.all(color: Colors.white.withOpacity(0.28)),
                                          ),
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Icon(Icons.screen_rotation_rounded, color: Colors.white.withOpacity(0.95), size: 20),
                                                const SizedBox(width: 8),
                                                Text(
                                                  '全屏观看',
                                                  style: TextStyle(
                                                    color: Colors.white.withOpacity(0.95),
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
                                );
                              },
                            ),
                          VodFullscreenChrome(
                          key: _chromeKey,
                          player: widget.playback,
                          title: _title,
                          visible: _showChrome && !_dragging && _dragDy.abs() < 4,
                          onToggleVisible: () {
                            _bumpChrome();
                          },
                          onExit: () => unawaited(_exitFullscreen()),
                          onBump: _bumpChrome,
                          episodes: widget.episodes,
                          epIdx: _epIdx,
                          aspect: _aspect,
                          onAspectChanged: (a) => setState(() => _aspect = a),
                          playUrl: widget.playUrl,
                          decodeMode: _decodeMode,
                          renderMode: _renderMode,
                          onDecodeChanged: (m) => unawaited(_onDecode(m)),
                          onRenderChanged: (m) => unawaited(_onRender(m)),
                          onPersistSetting: widget.onPersistSetting,
                          onPlayerStatus: widget.onPlayerStatus,
                          onExternalPlayer: widget.onExternalPlayer,
                          onToggleKeep: widget.onToggleKeep,
                          keepLabel: widget.keepLabel,
                          onParse: widget.onParse,
                          onRefresh: widget.onRefresh,
                          onCast: widget.onCast,
                          onMini: widget.onMini,
                          danmakuOn: _danmakuOn,
                          onDanmakuChanged: (v) {
                            setState(() => _danmakuOn = v);
                            widget.onDanmakuChanged?.call(v);
                          },
                          ambientOn: _ambientOn,
                          onAmbientChanged: (v) {
                            setState(() => _ambientOn = v);
                            widget.onAmbientChanged?.call(v);
                          },
                          stableVolumeOn: widget.stableVolumeOn,
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
                        ),
                      ],
                    );
                    if (_dragDy.abs() < 0.5) return videoStack;
                    return Transform.translate(
                      offset: Offset(0, _dragDy),
                      child: videoStack,
                    );
                  },
                ),
                  if (_swipeHint != null)
                    IgnorePointer(
                      child: Center(
                        child: AnimatedOpacity(
                          opacity: 1,
                          duration: const Duration(milliseconds: 120),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.62),
                              borderRadius: BorderRadius.circular(22),
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
