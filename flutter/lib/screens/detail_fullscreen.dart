import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../player/danmaku_layer.dart';
import '../player/embed_video_view.dart';
import '../player/kotv_playback.dart';
import '../widgets/vod_player_chrome.dart';

/// 详情页全屏：MPV / VLC 共用同一套顶底控件。
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
  StreamSubscription<bool>? _endedSub;
  StreamSubscription<Duration>? _posSub;
  Duration _pos = Duration.zero;
  final GlobalKey<VodFullscreenChromeState> _chromeKey = GlobalKey<VodFullscreenChromeState>();

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
      if (mounted) setState(() => _pos = d);
    });
    _endedSub = widget.playback.completedStream.listen((done) {
      if (!done || !mounted) return;
      final next = _epIdx + 1;
      if (next < widget.episodes.length) {
        setState(() => _epIdx = next);
      }
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
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _endedSub?.cancel();
    _posSub?.cancel();
    super.dispose();
  }

  bool get _epOpen => _chromeKey.currentState?.epOpen ?? false;

  void _bumpChrome() {
    _hideTimer?.cancel();
    setState(() => _showChrome = true);
    _hideTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && !_epOpen) setState(() => _showChrome = false);
    });
  }

  Future<void> _onDecode(String mode) async {
    setState(() => _decodeMode = mode);
    await widget.playback.setDecodeMode(mode);
    widget.onDecodeChanged?.call(mode);
  }

  void _goNext() {
    widget.onNext?.call();
    final next = _epIdx + 1;
    if (next < widget.episodes.length) {
      setState(() => _epIdx = next);
    }
    _bumpChrome();
  }

  void _goPrev() {
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

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.goBack) {
      if (_epOpen) {
        _chromeKey.currentState?.closeEpisodes();
        setState(() {});
        return KeyEventResult.handled;
      }
      Navigator.of(context).maybePop();
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
    if (pb is EngineVlcPlayback) {
      video = EmbedVideoView(playback: pb, fit: _aspect.fit, aspectRatio: _aspect.ratio);
    } else if (pb is MediaKitPlayback) {
      final mk = Video(controller: pb.controller, controls: NoVideoControls, fit: _aspect.fit);
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
                    onDoubleTap: () => Navigator.of(context).maybePop(),
                    child: _buildVideo(),
                  ),
                  DanmakuOverlay(
                    enabled: _danmakuOn,
                    position: _pos,
                    items: widget.danmakuItems,
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
                    onExit: () => Navigator.of(context).maybePop(),
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
