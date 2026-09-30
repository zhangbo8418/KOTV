import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../player/kotv_playback.dart';
import '../player/tv_remote_keys.dart';
import '../theme/kotv_palette.dart';
import '../theme/kotv_theme.dart';

/// 进度条：拖动只改 UI，松手才 [KotvPlayback.seek]。
///
/// seek 完成前钉住目标位置，避免播放器短暂回报 0 导致进度条闪回开头。
/// 钉住清除必须听 [KotvPlayback.positionStream]：桌面 MPV（MediaKit）不因
/// position 调 [ChangeNotifier.notifyListeners]。
///
/// 遥控：获焦高亮；左右步进 seek；上下 [FocusNode.focusInDirection]。
class KotvSeekSlider extends StatefulWidget {
  const KotvSeekSlider({
    super.key,
    required this.player,
    required this.maxMs,
    this.secondaryMs,
    this.enabled = true,
    this.onInteraction,
    this.theme,
    this.focusNode,
  });

  final KotvPlayback player;
  final double maxMs;
  final double? secondaryMs;
  final bool enabled;
  final VoidCallback? onInteraction;
  final SliderThemeData? theme;
  final FocusNode? focusNode;

  @override
  State<KotvSeekSlider> createState() => _KotvSeekSliderState();
}

class _KotvSeekSliderState extends State<KotvSeekSlider> {
  double? _scrubMs;
  double? _pendingSeekMs;
  StreamSubscription<Duration>? _posSub;
  FocusNode? _ownedFocus;
  bool _highlight = false;
  final FocusNode _sliderFocus = FocusNode(canRequestFocus: false, skipTraversal: true);

  FocusNode get _focus => widget.focusNode ?? _ownedFocus!;

  @override
  void initState() {
    super.initState();
    if (widget.focusNode == null) {
      _ownedFocus = FocusNode(debugLabel: 'kotv_seek');
    }
    _focus.onKeyEvent = _onKey;
    _wirePosition(widget.player);
  }

  @override
  void didUpdateWidget(covariant KotvSeekSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      _unwirePosition();
      _wirePosition(widget.player);
      _scrubMs = null;
      _pendingSeekMs = null;
    }
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode?.onKeyEvent = null;
      _ownedFocus?.onKeyEvent = null;
      if (widget.focusNode == null) {
        _ownedFocus ??= FocusNode(debugLabel: 'kotv_seek');
      } else if (_ownedFocus != null) {
        _ownedFocus!.dispose();
        _ownedFocus = null;
      }
      _focus.onKeyEvent = _onKey;
    }
  }

  @override
  void dispose() {
    _unwirePosition();
    _focus.onKeyEvent = null;
    _ownedFocus?.dispose();
    _sliderFocus.dispose();
    super.dispose();
  }

  void _unwirePosition() {
    _posSub?.cancel();
    _posSub = null;
  }

  void _wirePosition(KotvPlayback player) {
    _posSub = player.positionStream.listen((_) {
      final pending = _pendingSeekMs;
      if (pending == null || !mounted) return;
      final max = widget.maxMs <= 0 ? 1.0 : widget.maxMs;
      final live = player.position.inMilliseconds.toDouble().clamp(0.0, max);
      if ((live - pending).abs() <= 1500) {
        setState(() => _pendingSeekMs = null);
      }
    });
  }

  double get _max => widget.maxMs <= 0 ? 1.0 : widget.maxMs;

  double get _value {
    final live = widget.player.position.inMilliseconds.toDouble().clamp(0.0, _max);
    return (_scrubMs ?? _pendingSeekMs ?? live).clamp(0.0, _max);
  }

  void _seekTo(double ms) {
    final v = ms.clamp(0.0, _max);
    setState(() {
      _scrubMs = null;
      _pendingSeekMs = v;
    });
    widget.player.seek(Duration(milliseconds: v.round()));
    widget.onInteraction?.call();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!widget.enabled) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final max = _max;
    final cur = _value;

    if (kotvIsLeftKey(key) || kotvIsRightKey(key)) {
      final forward = kotvIsRightKey(key);
      final step = event is KeyRepeatEvent
          ? (max * 0.01).clamp(1000.0, 5000.0)
          : (max * 0.02).clamp(5000.0, 15000.0);
      _seekTo(cur + (forward ? step : -step));
      return KeyEventResult.handled;
    }
    if (kotvIsUpKey(key)) {
      return node.focusInDirection(TraversalDirection.up) ? KeyEventResult.handled : KeyEventResult.ignored;
    }
    if (kotvIsDownKey(key)) {
      return node.focusInDirection(TraversalDirection.down) ? KeyEventResult.handled : KeyEventResult.ignored;
    }
    return KeyEventResult.ignored;
  }

  Color _ringColor(Color focus) {
    if (focus.computeLuminance() >= 0.4) return focus;
    return Color.lerp(focus, Colors.white, 0.55) ?? focus;
  }

  @override
  Widget build(BuildContext context) {
    final max = _max;
    final value = _value;
    final live = widget.player.position.inMilliseconds.toDouble().clamp(0.0, max);
    final secondary = (widget.secondaryMs ?? live).clamp(0.0, max);
    final ring = _ringColor(KotvPalette.of(context).focus);

    final slider = Slider(
      focusNode: _sliderFocus,
      value: value,
      secondaryTrackValue: secondary < value ? value : secondary,
      max: max,
      onChangeStart: widget.enabled
          ? (v) {
              setState(() {
                _pendingSeekMs = null;
                _scrubMs = v;
              });
              widget.onInteraction?.call();
            }
          : null,
      onChanged: widget.enabled
          ? (v) {
              setState(() => _scrubMs = v);
              widget.onInteraction?.call();
            }
          : null,
      onChangeEnd: widget.enabled
          ? (v) {
              setState(() {
                _scrubMs = null;
                _pendingSeekMs = v;
              });
              widget.player.seek(Duration(milliseconds: v.round()));
              widget.onInteraction?.call();
            }
          : null,
    );

    final themed = widget.theme != null
        ? SliderTheme(data: widget.theme!, child: slider)
        : SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              activeTrackColor: KotvColors.primary,
              inactiveTrackColor: Colors.white24,
              secondaryActiveTrackColor: Colors.white38,
              thumbColor: Colors.white,
            ),
            child: slider,
          );

    return FocusableActionDetector(
      focusNode: _focus,
      onShowFocusHighlight: (v) {
        if (_highlight == v) return;
        setState(() => _highlight = v);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(vertical: 2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: _highlight ? ring.withOpacity(0.18) : null,
          border: Border.all(
            color: _highlight ? ring : Colors.transparent,
            width: _highlight ? 2 : 0,
          ),
          boxShadow: _highlight
              ? [BoxShadow(color: ring.withOpacity(0.45), blurRadius: 10, spreadRadius: 0)]
              : null,
        ),
        child: themed,
      ),
    );
  }
}
