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
import '../player/kotv_playback.dart';
import '../player/kotv_platform.dart';
import '../player/vp_playback.dart';
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
  State<DetailFullscreenPage> createState() => _DetailFullscreenPageState();
}

class _DetailFullscreenPageState extends State<DetailFullscreenPage> {
  bool _showChrome = true;
  late AspectSpec _aspect = widget.aspect;
  late String _decodeMode = widget.decodeMode;
  late int _epIdx = widget.epIdx;
  late bool _danmakuOn = widget.danmakuOn;
  late bool _ambientOn = widget.ambientOn;
  Timer? _hideTimer;
  StreamSubscription<Duration>? _posSub;
  Duration _pos = Duration.zero;
  final GlobalKey<VodFullscreenChromeState> _chromeKey = GlobalKey<VodFullscreenChromeState>();

  /// 抖音式上下滑切集
  double _dragDy = 0;
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
    _bumpChrome();
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
      if (mounted) _refreshForceLandscapeBtn();
    });
  }

  @override
  void didUpdateWidget(covariant DetailFullscreenPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.decodeMode != widget.decodeMode) _decodeMode = widget.decodeMode;
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
    _posSub?.cancel();
    widget.playback.removeListener(_onPlaybackChanged);
    unawaited(_restoreChrome());
    super.dispose();
  }

  void _onPlaybackChanged() => _refreshForceLandscapeBtn();

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

  void _bumpChrome() {
    _hideTimer?.cancel();
    setState(() => _showChrome = true);
    _hideTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && !_epOpen) setState(() => _showChrome = false);
    });
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

  void _onVerticalDragEnd(DragEndDetails d) {
    if (_epOpen || widget.episodes.isEmpty) {
      _dragDy = 0;
      return;
    }
    final now = DateTime.now();
    if (_lastSwipeAt != null && now.difference(_lastSwipeAt!) < const Duration(milliseconds: 650)) {
      _dragDy = 0;
      return;
    }
    final v = d.primaryVelocity ?? 0;
    // 上滑 = 下一集（抖音同款）；下滑 = 上一集
    if (v < -380 || _dragDy < -72) {
      _lastSwipeAt = now;
      final next = _epIdx + 1;
      final name = next >= 0 && next < widget.episodes.length ? widget.episodes[next] : '';
      _flashSwipeHint(name.isEmpty ? '下一集' : '下一集 · $name');
      _goNext();
    } else if (v > 380 || _dragDy > 72) {
      _lastSwipeAt = now;
      final prev = _epIdx - 1;
      final name = prev >= 0 && prev < widget.episodes.length ? widget.episodes[prev] : '';
      _flashSwipeHint(name.isEmpty ? '上一集' : '上一集 · $name');
      _goPrev();
    }
    _dragDy = 0;
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
    final onRight = e.localPosition.dx >= c.maxWidth - 24;
    if (onRight && !_epOpen && widget.episodes.isNotEmpty) {
      _chromeKey.currentState?.openEpisodes();
      setState(() {});
    }
    if (_showChrome) _bumpChrome();
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
    } else if (pb is VpPlayback) {
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
              onHover: (e) => _onHover(e, c),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      if (_epOpen) {
                        _chromeKey.currentState?.closeEpisodes();
                        setState(() {});
                        return;
                      }
                      setState(() => _showChrome = !_showChrome);
                      if (_showChrome) _bumpChrome();
                    },
                    onDoubleTap: () => unawaited(_exitFullscreen()),
                    onVerticalDragStart: _epOpen ? null : (_) => _dragDy = 0,
                    onVerticalDragUpdate: _epOpen
                        ? null
                        : (d) {
                            _dragDy += d.delta.dy;
                          },
                    onVerticalDragEnd: _epOpen ? null : _onVerticalDragEnd,
                    child: _buildVideo(),
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
                        final screen = MediaQuery.sizeOf(context);
                        final videoRect = kotvVideoContainRect(
                          screen: screen,
                          videoWidth: widget.playback.width,
                          videoHeight: widget.playback.height,
                        );
                        // 抖音式：按钮落在画面下方 letterbox 黑边，不叠在视频上。
                        final barTop = videoRect.bottom;
                        final barH = (screen.height - barTop).clamp(48.0, screen.height);
                        return Positioned(
                          left: 0,
                          right: 0,
                          top: barTop,
                          height: barH,
                          child: Center(
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
                  VodFullscreenChrome(
                    key: _chromeKey,
                    player: widget.playback,
                    title: _title,
                    visible: _showChrome,
                    onToggleVisible: () {
                      setState(() => _showChrome = !_showChrome);
                      if (_showChrome) _bumpChrome();
                    },
                    onExit: () => unawaited(_exitFullscreen()),
                    onBump: _bumpChrome,
                    episodes: widget.episodes,
                    epIdx: _epIdx,
                    aspect: _aspect,
                    onAspectChanged: (a) => setState(() => _aspect = a),
                    playUrl: widget.playUrl,
                    decodeMode: _decodeMode,
                    onDecodeChanged: (m) => unawaited(_onDecode(m)),
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
              ),
            );
          },
        ),
      ),
    );
  }
}
