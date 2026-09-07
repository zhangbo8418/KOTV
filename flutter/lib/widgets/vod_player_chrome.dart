import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../player/fullscreen_mode.dart';
import '../player/kotv_playback.dart';
import '../player/kotv_platform.dart';
import '../remote/remote_bridge.dart';
import '../theme/kotv_theme.dart';
import '../theme/layout_scale.dart';
import 'fullscreen_expand_button.dart';
import 'seek_slider.dart';

const _speeds = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

/// key / 标签 / BoxFit / 固定画幅比（16:9、4:3 时非空）。
const _aspects = <(String key, String label, BoxFit fit, double? ratio)>[
  ('default', '适应', BoxFit.contain, null),
  ('fill', '拉伸', BoxFit.fill, null),
  ('zoom', 'Zoom', BoxFit.cover, null),
  ('16:9', '16:9', BoxFit.fill, 16 / 9),
  ('4:3', '4:3', BoxFit.fill, 4 / 3),
];

class AspectSpec {
  const AspectSpec({required this.key, required this.fit, this.ratio});
  final String key;
  final BoxFit fit;
  final double? ratio;
}

String fmtPlayerTime(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  if (h > 0) return '$h:$m:$s';
  return '$m:$s';
}

String fmtClockHms(Duration d) {
  final h = d.inHours.toString().padLeft(2, '0');
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$h:$m:$s';
}

String fmtMmSs(int sec) {
  final s = sec < 0 ? 0 : sec;
  return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
}

/// 画面正中播停键：随控件一起出现；点击真正播/停。
class CenterPlayPauseButton extends StatelessWidget {
  const CenterPlayPauseButton({
    super.key,
    required this.player,
    this.enabled = true,
    this.visible = true,
    this.hideWhenBuffering = true,
    this.showWhilePlaying = false,
    this.autofocus = false,
    this.onPressed,
  });

  final KotvPlayback player;
  final bool enabled;
  final bool visible;
  /// 起播/卡顿补缓存时隐藏，避免和「缓冲中」叠在一起。
  final bool hideWhenBuffering;
  /// 控件层展开时同时显示暂停键；内嵌点播仍可只在暂停时出三角。
  final bool showWhilePlaying;
  final bool autofocus;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        if (!enabled || !visible) return const SizedBox.shrink();
        if (hideWhenBuffering && player.stalling) return const SizedBox.shrink();
        if (player.playing && !showWhilePlaying) return const SizedBox.shrink();
        final land = KotvLayout.isLandscapeCompact(context);
        final size = land ? 56.0 : 72.0;
        void toggle() {
          unawaited(player.playOrPause());
          onPressed?.call();
        }
        return Center(
          child: TvFocus(
            autofocus: autofocus,
            onPressed: toggle,
            borderRadius: size / 2,
            child: Material(
              color: const Color(0x73000000),
              shape: const CircleBorder(),
              elevation: 0,
              child: SizedBox(
                width: size,
                height: size,
                child: Icon(
                  player.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: size * 0.58,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 详情页内嵌播放器底栏（video_surface）。
class VodInlineControls extends StatelessWidget {
  const VodInlineControls({
    super.key,
    required this.player,
    this.onExpand,
    this.onStop,
    this.onCast,
    this.onMini,
    this.miniActive = false,
    this.translucent = false,
    this.autofocusPlay = false,
  });

  final KotvPlayback player;
  final ValueChanged<KotvDesktopFullscreenKind>? onExpand;
  final VoidCallback? onStop;
  final VoidCallback? onCast;
  final VoidCallback? onMini;
  final bool miniActive;
  final bool translucent;
  final bool autofocusPlay;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: translucent ? const Color(0x660A0A12) : const Color(0xCC0A0A12),
      child: ListenableBuilder(
        listenable: player,
        builder: (context, _) {
          final pos = player.position;
          final dur = player.duration;
          final total = dur.inMilliseconds <= 0 ? 1.0 : dur.inMilliseconds.toDouble();
          final vol = player.volume.clamp(0, 100).toDouble();
          return LayoutBuilder(
            builder: (context, constraints) {
              // 仅迷你窗缩控件；详情内嵌始终显示「当前 / 总时长」
              final narrow = miniActive || constraints.maxWidth < 480;
              final iconSize = narrow ? 32.0 : 40.0;
              final volW = narrow ? 72.0 : 110.0;
              return Padding(
                padding: EdgeInsets.fromLTRB(narrow ? 4 : 8, narrow ? 2 : 6, narrow ? 4 : 8, narrow ? 2 : 6),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        _IconAct(
                          icon: player.playing ? Icons.pause : Icons.play_arrow,
                          tip: player.playing ? '暂停' : '播放',
                          size: iconSize,
                          autofocus: autofocusPlay,
                          onTap: () => player.playOrPause(),
                        ),
                        _IconAct(
                          icon: Icons.stop,
                          tip: '停止',
                          size: iconSize,
                          onTap: () {
                            player.stop();
                            onStop?.call();
                          },
                        ),
                        if (onCast != null)
                          _IconAct(icon: Icons.cast, tip: '投屏', size: iconSize, onTap: onCast!),
                        if (onMini != null)
                          _IconAct(
                            icon: miniActive ? Icons.close_fullscreen : Icons.picture_in_picture_alt,
                            tip: miniActive ? '还原窗口' : '迷你桌面播放',
                            size: iconSize,
                            onTap: onMini!,
                          ),
                        if (onExpand != null && !miniActive)
                          KotvFullscreenExpandButton(size: iconSize, onSelect: onExpand!),
                        SizedBox(width: narrow ? 4 : 8),
                        Flexible(
                          child: Text(
                            '${fmtPlayerTime(pos)} / ${fmtPlayerTime(dur)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: Colors.white.withOpacity(0.75), fontSize: narrow ? 11 : 12),
                          ),
                        ),
                        if (!narrow) ...[
                          const Spacer(),
                          Text('音量', style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 12)),
                        ] else
                          const SizedBox(width: 4),
                        SizedBox(
                          width: volW,
                          child: ExcludeFocus(
                            child: SliderTheme(
                              data: _sliderTheme(context),
                              child: Slider(
                                value: vol,
                                max: 100,
                                onChanged: (v) => player.setVolume(v),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    ExcludeFocus(
                      child: KotvSeekSlider(
                        player: player,
                        maxMs: total,
                        secondaryMs: _sliderBuffered(player, total),
                        theme: _sliderTheme(context),
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

SliderThemeData _sliderTheme(BuildContext context) {
  return SliderTheme.of(context).copyWith(
    trackHeight: 3,
    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
    overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
    activeTrackColor: KotvColors.primary,
    inactiveTrackColor: Colors.white24,
    secondaryActiveTrackColor: Colors.white38,
    thumbColor: Colors.white,
  );
}

double _sliderBuffered(KotvPlayback player, double total) {
  // 部分引擎常在 duration 仍为 0 时已有 position（续播/缓冲），
  // 若 pos > total，`buf.clamp(pos, total)` 会抛 Invalid argument(s): pos。
  if (total <= 0) return 0;
  final pos = player.position.inMilliseconds.toDouble().clamp(0.0, total);
  final buf = player.buffered.inMilliseconds.toDouble().clamp(0.0, total);
  return buf < pos ? pos : buf;
}

class _IconAct extends StatelessWidget {
  const _IconAct({
    required this.icon,
    required this.tip,
    required this.onTap,
    this.badge,
    this.size = 40,
    this.autofocus = false,
  });

  final IconData icon;
  final String tip;
  final VoidCallback onTap;
  final String? badge;
  final double size;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final iconSz = size <= 34 ? 18.0 : 22.0;
    return Tooltip(
      message: tip,
      child: TvFocus(
        autofocus: autofocus,
        onPressed: onTap,
        borderRadius: 8,
        child: SizedBox(
          width: size,
          height: size,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(icon, color: Colors.white, size: iconSz),
              if (badge != null)
                Positioned(
                  right: 2,
                  top: 2,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                    decoration: BoxDecoration(color: const Color(0xFFE52D27), borderRadius: BorderRadius.circular(4)),
                    child: Text(badge!, style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w700)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TextAct extends StatelessWidget {
  const _TextAct({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TvFocus(
      onPressed: onTap,
      borderRadius: 8,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
      ),
    );
  }
}

class _TinyBtn extends StatelessWidget {
  const _TinyBtn({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TvFocus(
      onPressed: onTap,
      borderRadius: 6,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0x33FFFFFF),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 12)),
      ),
    );
  }
}

const _decodeModes = <(String key, String label)>[
  ('auto', '自动'),
  ('soft', '软解码'),
  ('hard', '硬解码'),
];

const _renderModes = <(String key, String label)>[
  ('surface', 'GPU 硬渲染'),
  ('texture', 'CPU 软渲染'),
];

/// 全屏点播控制层状态（vodFullscreen 底栏）。
class VodFullscreenChrome extends StatefulWidget {
  const VodFullscreenChrome({
    super.key,
    required this.player,
    required this.title,
    required this.visible,
    required this.onToggleVisible,
    required this.onExit,
    required this.onBump,
    this.episodes = const [],
    this.epIdx = -1,
    this.onSelectEp,
    this.onNext,
    this.onPrev,
    this.onReplay,
    this.aspect = const AspectSpec(key: 'default', fit: BoxFit.contain),
    this.onAspectChanged,
    this.playUrl = '',
    this.decodeMode = 'auto',
    this.onDecodeChanged,
    this.renderMode = 'surface',
    this.onRenderChanged,
    this.onPersistSetting,
    this.onPlayerStatus,
    this.onExternalPlayer,
    this.onToggleKeep,
    this.keepLabel = '收藏',
    this.onParse,
    this.onRefresh,
    this.onCast,
    this.onMini,
    this.onRotate,
    this.rotateLabel,
    this.danmakuOn = false,
    this.onDanmakuChanged,
    this.ambientOn = false,
    this.onAmbientChanged,
    this.stableVolumeOn = false,
    this.offsetId = '',
    this.offsetSite = '',
    this.openingSec = 0,
    this.endingSec = 0,
    this.onOffsetsChanged,
  });

  final KotvPlayback player;
  final String title;
  final bool visible;
  final VoidCallback onToggleVisible;
  final VoidCallback onExit;
  final VoidCallback onBump;
  /// 手机抖音式：竖屏 ↔ 横屏全屏切换。
  final VoidCallback? onRotate;
  final String? rotateLabel;
  final List<String> episodes;
  final int epIdx;
  final void Function(int idx)? onSelectEp;
  final VoidCallback? onNext;
  final VoidCallback? onPrev;
  final VoidCallback? onReplay;
  final AspectSpec aspect;
  final ValueChanged<AspectSpec>? onAspectChanged;
  final String playUrl;
  final String decodeMode;
  final ValueChanged<String>? onDecodeChanged;
  final String renderMode;
  final ValueChanged<String>? onRenderChanged;
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
  final bool ambientOn;
  final ValueChanged<bool>? onAmbientChanged;
  final bool stableVolumeOn;
  final String offsetId;
  final String offsetSite;
  final int openingSec;
  final int endingSec;
  final void Function(int openingSec, int endingSec)? onOffsetsChanged;

  @override
  State<VodFullscreenChrome> createState() => VodFullscreenChromeState();
}

class VodFullscreenChromeState extends State<VodFullscreenChrome> {
  int _speedIdx = 2;
  int _aspectIdx = 0;
  int _decodeIdx = 0;
  int _renderIdx = 0;
  int _openingSec = 0;
  int _endingSec = 0;
  bool _loopSkip = true; // 有片头/片尾值即生效；开关仅用于临时关闭
  bool _endingSkipFired = false;
  bool _openingSeekDone = false;
  bool _repeatOne = false;
  bool _epOpen = false;
  bool _danmakuOn = false;
  bool _ambientOn = false;
  bool _stableVolume = false;
  int _sleepMinutes = 0;
  Timer? _sleepTimer;
  String _keepLabel = '收藏';
  String _playerVal = kotvDefaultVodPlayer();
  String _playerLabel = flutterPlayerLabel(kotvDefaultVodPlayer());
  Timer? _clockTimer;
  Timer? _epHideTimer;
  StreamSubscription<Duration>? _skipSub;
  DateTime _now = DateTime.now();
  final ScrollController _epScroll = ScrollController();
  static const double _epItemExtent = 52;

  @override
  void initState() {
    super.initState();
    _danmakuOn = widget.danmakuOn;
    _ambientOn = widget.ambientOn;
    _stableVolume = widget.stableVolumeOn;
    _keepLabel = widget.keepLabel;
    _openingSec = widget.openingSec;
    _endingSec = widget.endingSec;
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
    final rate = widget.player.rate;
    final i = _speeds.indexWhere((s) => (s - rate).abs() < 0.01);
    if (i >= 0) _speedIdx = i;
    final di = _decodeModes.indexWhere((e) => e.$1 == widget.decodeMode);
    if (di >= 0) _decodeIdx = di;
    final ri = _renderModes.indexWhere((e) => e.$1 == kotvNormalizePlayerRender(widget.renderMode));
    if (ri >= 0) _renderIdx = ri;
    final ai = _aspects.indexWhere((e) => e.$1 == widget.aspect.key);
    if (ai >= 0) _aspectIdx = ai;
    unawaited(_refreshPlayerLabel());
    if (_stableVolume) unawaited(_applyStableVolume(true));
    _skipSub = widget.player.positionStream.listen(_onPositionTick);
  }

  @override
  void didUpdateWidget(covariant VodFullscreenChrome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.decodeMode != widget.decodeMode) {
      final di = _decodeModes.indexWhere((e) => e.$1 == widget.decodeMode);
      if (di >= 0) _decodeIdx = di;
    }
    if (oldWidget.renderMode != widget.renderMode) {
      final ri = _renderModes.indexWhere((e) => e.$1 == kotvNormalizePlayerRender(widget.renderMode));
      if (ri >= 0) _renderIdx = ri;
    }
    if (oldWidget.keepLabel != widget.keepLabel) {
      _keepLabel = widget.keepLabel;
    }
    if (oldWidget.danmakuOn != widget.danmakuOn) {
      _danmakuOn = widget.danmakuOn;
    }
    if (oldWidget.ambientOn != widget.ambientOn) {
      _ambientOn = widget.ambientOn;
    }
    if (oldWidget.stableVolumeOn != widget.stableVolumeOn) {
      _stableVolume = widget.stableVolumeOn;
      unawaited(_applyStableVolume(_stableVolume));
    }
    if (oldWidget.aspect.key != widget.aspect.key) {
      final ai = _aspects.indexWhere((e) => e.$1 == widget.aspect.key);
      if (ai >= 0) _aspectIdx = ai;
    }
    if (oldWidget.openingSec != widget.openingSec || oldWidget.endingSec != widget.endingSec) {
      _openingSec = widget.openingSec;
      _endingSec = widget.endingSec;
    }
    if (oldWidget.epIdx != widget.epIdx) {
      _endingSkipFired = false;
      _openingSeekDone = false;
      if (_epOpen) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollEpIntoView());
      }
    }
    if (oldWidget.playUrl != widget.playUrl) {
      _endingSkipFired = false;
      _openingSeekDone = false;
    }
    if (!identical(oldWidget.player, widget.player)) {
      _skipSub?.cancel();
      _skipSub = widget.player.positionStream.listen(_onPositionTick);
      _endingSkipFired = false;
      _openingSeekDone = false;
      final rate = widget.player.rate;
      final i = _speeds.indexWhere((s) => (s - rate).abs() < 0.01);
      if (i >= 0) _speedIdx = i;
      unawaited(_refreshPlayerLabel());
    }
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _epHideTimer?.cancel();
    _sleepTimer?.cancel();
    _skipSub?.cancel();
    _epScroll.dispose();
    super.dispose();
  }

  bool get epOpen => _epOpen;

  void openEpisodes() {
    _epHideTimer?.cancel();
    setState(() => _epOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollEpIntoView());
  }

  void closeEpisodes() {
    _epHideTimer?.cancel();
    setState(() => _epOpen = false);
  }

  void _scrollEpIntoView() {
    final i = widget.epIdx;
    if (i < 0 || !_epScroll.hasClients) return;
    final pos = _epScroll.position;
    final target = (i * _epItemExtent).clamp(pos.minScrollExtent, pos.maxScrollExtent);
    _epScroll.jumpTo(target);
  }

  Future<void> _refreshPlayerLabel() async {
    try {
      final status = await widget.onPlayerStatus?.call() ?? {};
      final cur = kotvClampPlayerVal('${status['current'] ?? ''}'.trim(), live: false);
      if (!mounted) return;
      setState(() {
        _playerVal = cur;
        _playerLabel = flutterPlayerLabel(cur);
      });
    } catch (_) {
      if (!mounted) return;
      final cur = kotvDefaultVodPlayer();
      setState(() {
        _playerVal = cur;
        _playerLabel = flutterPlayerLabel(cur);
      });
    }
  }

  void _onPositionTick(Duration pos) {
    if (!_loopSkip) {
      _endingSkipFired = false;
      return;
    }
    final dur = widget.player.duration;
    if (dur.inMilliseconds <= 0) return;
    final openMs = _openingSec * 1000;
    final endMs = _endingSec * 1000;

    // 片头：startPositionMs = max(opening, position) —— 起播靠近片头时跳到 opening
    if (openMs > 0 && !_openingSeekDone) {
      if (pos.inMilliseconds + 800 < openMs) {
        _openingSeekDone = true;
        unawaited(widget.player.seek(Duration(milliseconds: openMs)));
        return;
      }
      if (pos.inMilliseconds >= openMs) {
        _openingSeekDone = true;
      }
    }

    // 片尾：`ending + position >= duration` → 下一集（无需额外开关）
    if (endMs > 0 && pos.inMilliseconds + endMs >= dur.inMilliseconds) {
      if (!_endingSkipFired && widget.onNext != null) {
        _endingSkipFired = true;
        _openingSeekDone = false;
        widget.onNext!();
      }
    } else {
      _endingSkipFired = false;
    }
  }

  Future<void> _setOffsets(int open, int end) async {
    setState(() {
      _openingSec = open.clamp(0, 3600);
      _endingSec = end.clamp(0, 3600);
    });
    widget.onOffsetsChanged?.call(_openingSec, _endingSec);
    if (widget.offsetId.isNotEmpty) {
      await LocalPlayOffsets.set(widget.offsetId, widget.offsetSite, _openingSec, _endingSec);
    }
  }

  Future<void> _persist(String key, String value) async {
    await widget.onPersistSetting?.call(key, value);
  }

  void _cycleSpeed() {
    setState(() => _speedIdx = (_speedIdx + 1) % _speeds.length);
    widget.player.setRate(_speeds[_speedIdx]);
    unawaited(_persist('playerSpeed', '${_speeds[_speedIdx]}'));
    widget.onBump();
  }

  void _cycleAspect() {
    setState(() => _aspectIdx = (_aspectIdx + 1) % _aspects.length);
    final a = _aspects[_aspectIdx];
    widget.onAspectChanged?.call(AspectSpec(key: a.$1, fit: a.$3, ratio: a.$4));
    unawaited(_persist('playerScale', a.$1));
    widget.onBump();
  }

  void _cycleDecode() {
    setState(() => _decodeIdx = (_decodeIdx + 1) % _decodeModes.length);
    final mode = _decodeModes[_decodeIdx].$1;
    unawaited(widget.player.setDecodeMode(mode));
    widget.onDecodeChanged?.call(mode);
    unawaited(_persist('playerDecode', mode));
    widget.onBump();
  }

  void _cycleRender() {
    setState(() => _renderIdx = (_renderIdx + 1) % _renderModes.length);
    final mode = _renderModes[_renderIdx].$1;
    unawaited(widget.player.setRenderMode(mode));
    widget.onRenderChanged?.call(mode);
    unawaited(_persist('playerRender', mode));
    widget.onBump();
  }

  Widget _chromeSheetFrame(
    BuildContext ctx, {
    required String title,
    String? subtitle,
    required List<Widget> children,
  }) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Material(
          color: const Color(0xCC2A2A30),
          borderRadius: BorderRadius.circular(18),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.72),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(4, 10, 4, 12),
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.28),
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700)),
                      if (subtitle != null && subtitle.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(subtitle, style: TextStyle(color: Colors.white.withOpacity(0.65), fontSize: 13)),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                ...children,
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _chromeSelectRow({
    IconData? icon,
    required String label,
    bool selected = false,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 52,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, color: Colors.white, size: 24),
                  const SizedBox(width: 16),
                ],
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
                if (selected) const Icon(Icons.check, color: Colors.white, size: 22),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showChromeListSheet({
    required String title,
    String? subtitle,
    required List<Widget> children,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black38,
      isScrollControlled: true,
      builder: (ctx) => _chromeSheetFrame(ctx, title: title, subtitle: subtitle, children: children),
    );
  }

  Future<void> _showTrackSheet({required String kind}) async {
    widget.onBump();
    final audio = kind == 'audio';
    final video = kind == 'video';
    final audioTracks = widget.player.audioTracks;
    final videoTracks = widget.player.videoTracks;
    final subTracks = widget.player.subtitleTracks;
    final currentAudio = widget.player.currentAudioId;
    final currentVideo = widget.player.currentVideoId;
    final currentSub = widget.player.currentSubtitleId;
    final rows = <Widget>[];
    if (video) {
      rows.add(
        _chromeSelectRow(
          icon: Icons.auto_awesome,
          label: '自动',
          selected: currentVideo == null || currentVideo == 'auto' || currentVideo.isEmpty,
          onTap: () async {
            await widget.player.setVideoTrack('auto');
            if (context.mounted) Navigator.pop(context);
          },
        ),
      );
      for (final t in videoTracks) {
        rows.add(
          _chromeSelectRow(
            label: t.label,
            selected: t.id == currentVideo,
            onTap: () async {
              await widget.player.setVideoTrack(t.id);
              if (context.mounted) Navigator.pop(context);
            },
          ),
        );
      }
      if (videoTracks.isEmpty) {
        rows.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Text('暂无可用视频轨', style: TextStyle(color: Colors.white.withOpacity(0.55), fontSize: 15)),
          ),
        );
      }
      await _showChromeListSheet(title: '视频轨', children: rows);
      return;
    }
    if (!audio) {
      rows.addAll([
        _chromeSelectRow(
          icon: Icons.closed_caption_off_outlined,
          label: '关闭字幕',
          selected: kotvSubtitleIsOff(currentSub),
          onTap: () async {
            await widget.player.setSubtitleTrack('');
            if (context.mounted) Navigator.pop(context);
          },
        ),
        _chromeSelectRow(
          icon: Icons.auto_awesome,
          label: '自动',
          selected: kotvSubtitleIsAuto(currentSub),
          onTap: () async {
            await widget.player.setSubtitleTrack('auto');
            if (context.mounted) Navigator.pop(context);
          },
        ),
        for (final t in subTracks)
          _chromeSelectRow(
            label: t.label,
            selected: t.id == currentSub,
            onTap: () async {
              await widget.player.setSubtitleTrack(t.id);
              if (context.mounted) Navigator.pop(context);
            },
          ),
      ]);
      if (subTracks.isEmpty) {
        rows.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Text('暂无可用字幕轨', style: TextStyle(color: Colors.white.withOpacity(0.55), fontSize: 15)),
          ),
        );
      }
    } else {
      rows.add(
        _chromeSelectRow(
          icon: Icons.auto_awesome,
          label: '自动',
          selected: kotvAudioIsAuto(currentAudio),
          onTap: () async {
            await widget.player.setAudioTrack('auto');
            if (context.mounted) Navigator.pop(context);
          },
        ),
      );
      for (final t in audioTracks) {
        rows.add(
          _chromeSelectRow(
            label: t.label,
            selected: t.id == currentAudio,
            onTap: () async {
              await widget.player.setAudioTrack(t.id);
              if (context.mounted) Navigator.pop(context);
            },
          ),
        );
      }
      if (audioTracks.isEmpty) {
        rows.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Text('暂无可用音轨', style: TextStyle(color: Colors.white.withOpacity(0.55), fontSize: 15)),
          ),
        );
      }
    }
    await _showChromeListSheet(title: audio ? '音轨' : '字幕', children: rows);
  }

  Future<void> _showPlayerDialog() async {
    widget.onBump();
    if (!kotvCanSwitchPlayer(live: false)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('当前平台仅支持${flutterPlayerLabel(kotvDefaultVodPlayer())}')),
        );
      }
      return;
    }
    Map<String, dynamic> status = {};
    try {
      status = await widget.onPlayerStatus?.call() ?? {};
    } catch (_) {}
    final avail = Map<String, dynamic>.from((status['available'] as Map?) ?? const {});
    final cur = kotvClampPlayerVal('${status['current'] ?? ''}'.trim(), live: false);
    if (mounted) {
      setState(() {
        _playerVal = cur;
        _playerLabel = flutterPlayerLabel(cur);
      });
    }

    // 内置后端按平台分流；外置仅桌面。
    final opts = <(String label, String val, String key)>[
      if (kIsWeb) ...[
        ('浏览器播放（HTML5）', 'innie#html', 'embed_html'),
        ('ArtPlayer', 'innie#art', 'embed_art'),
        ('西瓜播放器（xgplayer）', 'innie#xg', 'embed_xg'),
        ('全能播放器（ZWPlayer）', 'innie#zw', 'embed_zw'),
      ] else if (kotvIsAndroid()) ...[
        ('内置 ExoPlayer', 'innie#exo', 'embed_exo'),
        ('内置 MPV', 'innie#mpv', 'embed_mpv'),
        ('内置 FVP', 'innie#fvp', 'embed_fvp'),
      ] else if (kotvIsIOS()) ...[
        ('内置 MPV', 'innie#mpv', 'embed_mpv'),
        ('内置 FVP', 'innie#fvp', 'embed_fvp'),
        ('浏览器播放（HTML5）', 'innie#html', 'embed_html'),
      ] else ...[
        ('内置 MPV', 'innie#mpv', 'embed_mpv'),
        ('内置 FVP', 'innie#fvp', 'embed_fvp'),
        ('外部 MPV', 'outie#mpv', 'mpv'),
        ('外部 VLC', 'outie#vlc', 'vlc'),
        ('IINA', 'outie#iina', 'iina'),
      ],
    ];

    bool listed(String key) {
      // Flutter 内置 MPV/FVP/Exo/HTML/JS 播放器不依赖引擎 runtime。
      if (key == 'embed_mpv' ||
          key == 'embed_exo' ||
          key == 'embed_fvp' ||
          key == 'embed_html' ||
          key == 'embed_art' ||
          key == 'embed_xg' ||
          key == 'embed_zw') {
        return true;
      }
      return avail[key] == true;
    }

    if (!mounted) return;
    final rows = <Widget>[
      for (final o in opts)
        if (listed(o.$3))
          _chromeSelectRow(
            icon: Icons.smart_display_outlined,
            label: o.$1,
            selected: cur == o.$2,
            onTap: () async {
              Navigator.pop(context);
              await _selectPlayer(o.$2);
            },
          ),
    ];
    await _showChromeListSheet(
      title: '请选择播放器',
      subtitle: '当前：${flutterPlayerLabel(cur)}',
      children: rows,
    );
  }

  Future<void> _selectPlayer(String val) async {
    final next = kotvClampPlayerVal(val, live: false);
    await _persist('player', next);
    if (mounted) {
      setState(() {
        _playerVal = next;
        _playerLabel = flutterPlayerLabel(next);
      });
    }
    if (next.startsWith('outie#')) {
      final url = widget.playUrl;
      if (url.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('当前无播放地址')));
        }
        return;
      }
      try {
        await widget.onExternalPlayer?.call(next);
        await widget.player.pause();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已用${flutterPlayerLabel(next)}打开')));
          widget.onExit();
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
        }
      }
    } else {
      // 内置切换由 onPersistSetting → 父页 _playAt 真正换引擎；勿对旧实例 seek+play。
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已切换为$_playerLabel')));
      }
    }
  }

  Future<void> _showMore() async {
    widget.onBump();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black38,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            void sync(VoidCallback fn) {
              setState(fn);
              setSheet(() {});
            }

            Widget toggleRow({
              required IconData icon,
              required String label,
              required bool value,
              required ValueChanged<bool> onChanged,
            }) {
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                child: SizedBox(
                  height: 52,
                  child: Row(
                    children: [
                      const SizedBox(width: 8),
                      Icon(icon, color: Colors.white, size: 24),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500)),
                      ),
                      Switch.adaptive(
                        value: value,
                        activeColor: Colors.white,
                        activeTrackColor: const Color(0xFF5C5C66),
                        inactiveThumbColor: const Color(0xFFB0B0B8),
                        inactiveTrackColor: const Color(0xFF3A3A42),
                        onChanged: onChanged,
                      ),
                      const SizedBox(width: 4),
                    ],
                  ),
                ),
              );
            }

            Widget linkRow({
              required IconData icon,
              required String label,
              String trailing = '',
              required VoidCallback onTap,
            }) {
              return Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: onTap,
                  child: SizedBox(
                    height: 52,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          Icon(icon, color: Colors.white, size: 24),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500)),
                          ),
                          Text(
                            trailing.isEmpty ? '' : trailing,
                            style: TextStyle(color: Colors.white.withOpacity(0.55), fontSize: 15),
                          ),
                          Icon(Icons.chevron_right, color: Colors.white.withOpacity(0.45), size: 22),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }

            final sleepLabel = _sleepMinutes <= 0 ? '关闭' : '$_sleepMinutes 分钟';

            return SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Material(
                  color: const Color(0xCC2A2A30),
                  borderRadius: BorderRadius.circular(18),
                  clipBehavior: Clip.antiAlias,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.72),
                    child: ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(4, 10, 4, 12),
                      children: [
                        Center(
                          child: Container(
                            width: 40,
                            height: 4,
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.28),
                              borderRadius: BorderRadius.circular(99),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        toggleRow(
                          icon: Icons.repeat,
                          label: '循环播放视频',
                          value: _repeatOne,
                          onChanged: (v) {
                            sync(() => _repeatOne = v);
                            unawaited(widget.player.setRepeatOne(v));
                          },
                        ),
                        toggleRow(
                          icon: Icons.wb_sunny_outlined,
                          label: '氛围模式',
                          value: _ambientOn,
                          onChanged: (v) {
                            sync(() => _ambientOn = v);
                            widget.onAmbientChanged?.call(v);
                            unawaited(_persist('playerAmbient', v ? 'true' : 'false'));
                          },
                        ),
                        toggleRow(
                          icon: Icons.graphic_eq,
                          label: '稳定音量',
                          value: _stableVolume,
                          onChanged: (v) {
                            sync(() => _stableVolume = v);
                            unawaited(_applyStableVolume(v));
                            unawaited(_persist('playerStableVolume', v ? 'true' : 'false'));
                          },
                        ),
                        toggleRow(
                          icon: Icons.skip_next_outlined,
                          label: '跳过片头片尾',
                          value: _loopSkip,
                          onChanged: (v) {
                            sync(() {
                              _loopSkip = v;
                              _endingSkipFired = false;
                              _openingSeekDone = false;
                            });
                            if (v) _onPositionTick(widget.player.position);
                          },
                        ),
                        toggleRow(
                          icon: Icons.subtitles_outlined,
                          label: '弹幕',
                          value: _danmakuOn,
                          onChanged: (v) {
                            sync(() => _danmakuOn = v);
                            widget.onDanmakuChanged?.call(v);
                            unawaited(_persist('danmaku', v ? 'true' : 'false'));
                          },
                        ),
                        linkRow(
                          icon: Icons.bedtime_outlined,
                          label: '休眠定时器',
                          trailing: sleepLabel,
                          onTap: () => unawaited(_pickSleepTimer(ctx, setSheet)),
                        ),
                        if (widget.onCast != null)
                          linkRow(
                            icon: Icons.cast,
                            label: '投屏',
                            onTap: () {
                              Navigator.pop(ctx);
                              widget.onCast!();
                            },
                          ),
                        if (widget.onMini != null)
                          linkRow(
                            icon: Icons.picture_in_picture_alt,
                            label: '迷你桌面播放',
                            onTap: () {
                              Navigator.pop(ctx);
                              widget.onMini!();
                            },
                          ),
                        if (widget.onParse != null)
                          linkRow(
                            icon: Icons.auto_awesome,
                            label: '解析',
                            onTap: () {
                              Navigator.pop(ctx);
                              widget.onParse!();
                            },
                          ),
                        linkRow(
                          icon: Icons.refresh,
                          label: '刷新',
                          onTap: () {
                            Navigator.pop(ctx);
                            if (widget.onRefresh != null) {
                              widget.onRefresh!();
                            } else {
                              widget.onReplay?.call();
                              widget.player.seek(Duration.zero);
                              widget.player.play();
                            }
                          },
                        ),
                        if (widget.onToggleKeep != null)
                          linkRow(
                            icon: Icons.favorite_border,
                            label: _keepLabel,
                            onTap: () async {
                              Navigator.pop(ctx);
                              final label = await widget.onToggleKeep!();
                              if (mounted && label.isNotEmpty) setState(() => _keepLabel = label);
                            },
                          ),
                        if (kotvPlayerRenderApplies(_playerVal))
                          linkRow(
                            icon: Icons.layers_outlined,
                            label: '渲染方式',
                            trailing: _renderModes[_renderIdx].$2,
                            onTap: () {
                              Navigator.pop(ctx);
                              _cycleRender();
                            },
                          ),
                        linkRow(
                          icon: Icons.info_outline,
                          label: '播放信息',
                          onTap: () {
                            Navigator.pop(ctx);
                            _showPlayInfo();
                          },
                        ),
                        linkRow(
                          icon: Icons.fullscreen_exit,
                          label: '退出全屏',
                          onTap: () {
                            Navigator.pop(ctx);
                            widget.onExit();
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _applyStableVolume(bool on) async {
    await widget.player.setStableVolume(on);
  }

  Future<void> _pickSleepTimer(BuildContext sheetCtx, StateSetter setSheet) async {
    final picked = await showModalBottomSheet<int>(
      context: sheetCtx,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black38,
      isScrollControlled: true,
      builder: (ctx) {
        Widget opt(String label, int mins) {
          return _chromeSelectRow(
            icon: Icons.bedtime_outlined,
            label: label,
            selected: _sleepMinutes == mins,
            onTap: () => Navigator.pop(ctx, mins),
          );
        }

        return _chromeSheetFrame(
          ctx,
          title: '休眠定时器',
          children: [
            opt('关闭', 0),
            opt('15 分钟', 15),
            opt('30 分钟', 30),
            opt('45 分钟', 45),
            opt('60 分钟', 60),
          ],
        );
      },
    );
    if (picked == null) return;
    setState(() => _sleepMinutes = picked);
    setSheet(() {});
    _sleepTimer?.cancel();
    if (picked <= 0) return;
    _sleepTimer = Timer(Duration(minutes: picked), () {
      if (!mounted) return;
      setState(() => _sleepMinutes = 0);
      unawaited(widget.player.pause());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('休眠定时到，已暂停播放')));
      }
    });
  }

  void _showPlayInfo() {
    final w = widget.player.width;
    final h = widget.player.height;
    final pos = widget.player.position;
    final dur = widget.player.duration;
    unawaited(
      _showChromeListSheet(
        title: '播放信息',
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Text(
              '标题：${widget.title}\n'
              '分辨率：$w x $h\n'
              '进度：${fmtClockHms(pos)} / ${fmtClockHms(dur)}\n'
              '倍速：x${_speeds[_speedIdx]}\n'
              '比例：${_aspects[_aspectIdx].$2}\n'
              '解码：${_decodeModes[_decodeIdx].$2}\n'
              '播放器：${widget.player.engineLabel}',
              style: TextStyle(color: Colors.white.withOpacity(0.75), height: 1.55, fontSize: 15),
            ),
          ),
        ],
      ),
    );
  }

  String get _endsAt {
    final dur = widget.player.duration;
    final pos = widget.player.position;
    if (dur.inMilliseconds <= 0) return 'Ends at --:--';
    final left = dur - pos;
    if (left.isNegative) return 'Ends at --:--';
    final end = _now.add(left);
    final hh = end.hour.toString().padLeft(2, '0');
    final mm = end.minute.toString().padLeft(2, '0');
    return 'Ends at $hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    final padTop = MediaQuery.paddingOf(context).top;
    final w = widget.player.width;
    final h = widget.player.height;
    final res = '[ $w x $h ]';
    final land = KotvLayout.isLandscapeCompact(context);
    final titleSize = land ? 16.0 : 22.0;
    final clockSize = land ? 20.0 : 32.0;
    final padH = land ? 14.0 : 28.0;
    final padTopBar = land ? 6.0 : 12.0;
    final padBot = land ? 10.0 : 22.0;

    return Stack(
      fit: StackFit.expand,
      children: [
        if (widget.visible && !_epOpen)
          // 中心播停给触控；遥控器走底栏按钮，避免焦点停在画面正中出不去。
          ExcludeFocus(
            child: CenterPlayPauseButton(
              player: widget.player,
              enabled: widget.playUrl.isNotEmpty,
              showWhilePlaying: true,
              hideWhenBuffering: true,
              autofocus: false,
              onPressed: widget.onBump,
            ),
          ),
        if (widget.visible && !_epOpen) ...[
          // 顶栏
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: Container(
              color: const Color(0x66000000),
              padding: EdgeInsets.fromLTRB(padH, padTop + padTopBar, padH, land ? 8 : 14),
              child: Row(
                children: [
                  Container(width: 4, height: land ? 28 : 42, color: const Color(0xFFE52D27)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: Colors.white, fontSize: titleSize, fontWeight: FontWeight.w700),
                        ),
                        Text(res, style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: land ? 11 : 14)),
                      ],
                    ),
                  ),
                  if (widget.onRotate != null) ...[
                    _TextAct(
                      label: widget.rotateLabel ?? '旋转',
                      onTap: widget.onRotate!,
                    ),
                    const SizedBox(width: 8),
                  ],
                  _TextAct(label: '退出', onTap: widget.onExit),
                ],
              ),
            ),
          ),
          // 底栏
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Material(
              color: const Color(0x99000000),
              child: Padding(
                padding: EdgeInsets.fromLTRB(padH, land ? 6 : 12, padH, padBot),
                child: StreamBuilder(
                  stream: widget.player.positionStream,
                  builder: (context, _) {
                    final pos = widget.player.position;
                    final dur = widget.player.duration;
                    final total = dur.inMilliseconds <= 0 ? 1.0 : dur.inMilliseconds.toDouble();
                    final vol = widget.player.volume.clamp(0, 100).toDouble();
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Align(
                          alignment: Alignment.centerRight,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                '${_now.hour.toString().padLeft(2, '0')}:${_now.minute.toString().padLeft(2, '0')}:${_now.second.toString().padLeft(2, '0')}',
                                style: TextStyle(color: Colors.white, fontSize: clockSize, fontWeight: FontWeight.w700, height: 1),
                              ),
                              Text(_endsAt, style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: land ? 11 : 13)),
                            ],
                          ),
                        ),
                        SizedBox(height: land ? 2 : 4),
                        Row(
                          children: [
                            SizedBox(
                              width: land ? 64 : 78,
                              child: Text(fmtClockHms(pos), style: TextStyle(color: Colors.white.withOpacity(0.75), fontSize: land ? 11 : 13)),
                            ),
                            Expanded(
                              child: ExcludeFocus(
                                child: KotvSeekSlider(
                                  player: widget.player,
                                  maxMs: total,
                                  secondaryMs: _sliderBuffered(widget.player, total),
                                  theme: _sliderTheme(context),
                                  onInteraction: widget.onBump,
                                ),
                              ),
                            ),
                            SizedBox(
                              width: land ? 64 : 78,
                              child: Text(
                                fmtClockHms(dur),
                                textAlign: TextAlign.right,
                                style: TextStyle(color: Colors.white.withOpacity(0.75), fontSize: land ? 11 : 13),
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: land ? 2 : 6),
                        Row(
                          children: [
                            Expanded(
                              child: SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: Row(
                                  children: [
                                    _IconAct(icon: Icons.skip_previous, tip: '上一集', size: land ? 32.0 : 40.0, onTap: () {
                                      widget.onPrev?.call();
                                      widget.onBump();
                                    }),
                                    _IconAct(
                                      icon: widget.player.playing ? Icons.pause : Icons.play_arrow,
                                      tip: widget.player.playing ? '暂停' : '播放',
                                      size: land ? 32.0 : 40.0,
                                      autofocus: true,
                                      onTap: () {
                                        widget.player.playOrPause();
                                        widget.onBump();
                                        setState(() {});
                                      },
                                    ),
                                    _IconAct(icon: Icons.skip_next, tip: '下一集', size: land ? 32.0 : 40.0, onTap: () {
                                      widget.onNext?.call();
                                      widget.onBump();
                                    }),
                                    _IconAct(
                                      icon: Icons.fast_forward,
                                      tip: '倍速',
                                      badge: 'x${_speeds[_speedIdx]}',
                                      size: land ? 32.0 : 40.0,
                                      onTap: _cycleSpeed,
                                    ),
                                    _IconAct(icon: Icons.replay, tip: '重播', size: land ? 32.0 : 40.0, onTap: () {
                                      widget.onReplay?.call();
                                      widget.player.seek(Duration.zero);
                                      widget.player.play();
                                      widget.onBump();
                                    }),
                                    _IconAct(
                                      icon: Icons.aspect_ratio,
                                      tip: _aspects[_aspectIdx].$2,
                                      size: land ? 32.0 : 40.0,
                                      onTap: _cycleAspect,
                                    ),
                                    _IconAct(
                                      icon: Icons.memory,
                                      tip: _decodeModes[_decodeIdx].$2,
                                      badge: _decodeModes[_decodeIdx].$2.substring(0, 1),
                                      size: land ? 32.0 : 40.0,
                                      onTap: _cycleDecode,
                                    ),
                                    _IconAct(
                                      icon: Icons.closed_caption,
                                      tip: '字幕',
                                      size: land ? 32.0 : 40.0,
                                      onTap: () => _showTrackSheet(kind: 'subtitle'),
                                    ),
                                    _IconAct(
                                      icon: Icons.audiotrack,
                                      tip: '音轨',
                                      size: land ? 32.0 : 40.0,
                                      onTap: () => _showTrackSheet(kind: 'audio'),
                                    ),
                                    _IconAct(
                                      icon: Icons.videocam_outlined,
                                      tip: '视频轨',
                                      size: land ? 32.0 : 40.0,
                                      onTap: () => _showTrackSheet(kind: 'video'),
                                    ),
                                    if (kotvCanSwitchPlayer(live: false))
                                      _IconAct(
                                        icon: Icons.devices,
                                        tip: '播放器（$_playerLabel）',
                                        badge: flutterIsEmbedPlayer(_playerVal) ? '内' : '外',
                                        size: land ? 32.0 : 40.0,
                                        onTap: _showPlayerDialog,
                                      ),
                                    const SizedBox(width: 6),
                                    Container(width: 1, height: 26, color: const Color(0x4DFFFFFF)),
                                    const SizedBox(width: 8),
                                    _TinyBtn(label: '-', onTap: () {
                                      unawaited(_setOffsets(_openingSec - 5, _endingSec));
                                      widget.onBump();
                                    }),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 6),
                                      child: Text(fmtMmSs(_openingSec), style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                                    ),
                                    _TinyBtn(label: '+', onTap: () {
                                      unawaited(_setOffsets(_openingSec + 5, _endingSec));
                                      widget.onBump();
                                    }),
                                    const SizedBox(width: 8),
                                    _TinyBtn(label: '-', onTap: () {
                                      unawaited(_setOffsets(_openingSec, _endingSec - 5));
                                      widget.onBump();
                                    }),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 6),
                                      child: Text(fmtMmSs(_endingSec), style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                                    ),
                                    _TinyBtn(label: '+', onTap: () {
                                      unawaited(_setOffsets(_openingSec, _endingSec + 5));
                                      widget.onBump();
                                    }),
                                    const SizedBox(width: 8),
                                    _TinyBtn(
                                      label: '重置',
                                      onTap: () {
                                        unawaited(_setOffsets(0, 0));
                                        widget.onBump();
                                      },
                                    ),
                                    const SizedBox(width: 8),
                                    Container(width: 1, height: 26, color: const Color(0x4DFFFFFF)),
                                    const SizedBox(width: 4),
                                    _TextAct(label: '更多', onTap: _showMore),
                                    if (widget.episodes.isNotEmpty)
                                      _TextAct(label: '选集', onTap: () {
                                        openEpisodes();
                                        widget.onBump();
                                      }),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Text('音量', style: TextStyle(color: Colors.white.withOpacity(0.75), fontSize: 12)),
                            SizedBox(
                              width: 140,
                              child: ExcludeFocus(
                                child: SliderTheme(
                                  data: _sliderTheme(context),
                                  child: Slider(
                                    value: vol,
                                    max: 100,
                                    onChanged: (v) {
                                      widget.player.setVolume(v);
                                      unawaited(_persist('playerVolume', '${v.round()}'));
                                      widget.onBump();
                                    },
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ],
        if (_epOpen)
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            child: MouseRegion(
              onEnter: (_) {
                _epHideTimer?.cancel();
                widget.onBump();
              },
              onExit: (_) {
                _epHideTimer?.cancel();
                _epHideTimer = Timer(const Duration(seconds: 8), () {
                  if (mounted && _epOpen) setState(() => _epOpen = false);
                });
              },
              child: Material(
                color: const Color(0x990A0814),
                child: SizedBox(
                  width: KotvLayout.isLandscapeCompact(context) ? 220.0 : 300.0,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: EdgeInsets.fromLTRB(16, padTop + (KotvLayout.isLandscapeCompact(context) ? 8 : 14), 8, 10),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                '选集',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: KotvLayout.isLandscapeCompact(context) ? 16 : 20,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            IconButton(
                              onPressed: closeEpisodes,
                              icon: const Icon(Icons.close, color: Colors.white70),
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1, color: Color(0x44FFFFFF)),
                      Expanded(
                        child: Listener(
                          onPointerSignal: (e) {
                            if (e is! PointerScrollEvent || !_epScroll.hasClients) return;
                            final pos = _epScroll.position;
                            _epScroll.jumpTo(
                              (_epScroll.offset + e.scrollDelta.dy)
                                  .clamp(pos.minScrollExtent, pos.maxScrollExtent),
                            );
                          },
                          child: ListView.builder(
                            controller: _epScroll,
                            itemExtent: _epItemExtent,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            itemCount: widget.episodes.length,
                            itemBuilder: (_, i) {
                              final sel = i == widget.epIdx;
                              return Padding(
                                padding: const EdgeInsets.symmetric(vertical: 4),
                                child: Material(
                                  color: sel ? const Color(0x2EFFFFFF) : const Color(0x3318161E),
                                  borderRadius: BorderRadius.circular(8),
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(8),
                                    onTap: () {
                                      widget.onSelectEp?.call(i);
                                      closeEpisodes();
                                    },
                                    child: Align(
                                      alignment: Alignment.centerLeft,
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 14),
                                        child: Text(
                                          widget.episodes[i],
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: Colors.white.withOpacity(sel ? 1 : 0.85),
                                            fontSize: 14,
                                            fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                                          ),
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
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
