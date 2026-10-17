import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../player/kotv_playback.dart';
import '../player/tv_remote_keys.dart';
import '../theme/kotv_palette.dart';
import '../theme/kotv_theme.dart';
import '../theme/layout_scale.dart';

/// 播控右侧音量：默认只显示扬声器；获焦/悬停展开滑条；激活后左右键调音并落盘。
class KotvVolumeControl extends StatefulWidget {
  const KotvVolumeControl({
    super.key,
    required this.player,
    this.onPersist,
    this.onEngage,
    this.iconSize = 40,
    this.sliderWidth = 120,
    this.compact = false,
  });

  final KotvPlayback player;
  final Future<void> Function(int volume)? onPersist;
  final VoidCallback? onEngage;
  final double iconSize;
  final double sliderWidth;
  final bool compact;

  @override
  State<KotvVolumeControl> createState() => _KotvVolumeControlState();
}

class _KotvVolumeControlState extends State<KotvVolumeControl> with KotvKeyHighlightState {
  late final FocusNode _focus = FocusNode(debugLabel: 'kotv_volume', onKeyEvent: _onKey);
  bool _expanded = false;
  bool _hovering = false;
  bool _highlight = false;
  Timer? _collapseTimer;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _collapseTimer?.cancel();
    _focus.removeListener(_onFocusChanged);
    _focus.dispose();
    super.dispose();
  }

  /// 只管展开/收起；高亮走 [FocusableActionDetector.onShowFocusHighlight]（触控不留常亮框）。
  void _onFocusChanged() {
    if (_focus.hasFocus) {
      _collapseTimer?.cancel();
      if (!_expanded) setState(() => _expanded = true);
      widget.onEngage?.call();
    } else if (!_hovering) {
      _scheduleCollapse();
    }
  }

  void _scheduleCollapse() {
    _collapseTimer?.cancel();
    _collapseTimer = Timer(const Duration(milliseconds: 450), () {
      if (!mounted || _focus.hasFocus || _hovering) return;
      setState(() => _expanded = false);
    });
  }

  void _setHover(bool on) {
    _hovering = on;
    if (on) {
      _collapseTimer?.cancel();
      if (!_expanded) setState(() => _expanded = true);
      widget.onEngage?.call();
    } else if (!_focus.hasFocus) {
      _scheduleCollapse();
    }
  }

  int _clampVol(num v) => v.round().clamp(1, 100);

  Future<void> _applyVolume(double raw, {required bool persist}) async {
    final n = _clampVol(raw);
    await widget.player.setVolume(n.toDouble());
    widget.onEngage?.call();
    if (persist) {
      final p = widget.onPersist;
      if (p != null) await p(n);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final vol = widget.player.volume;

    if (kotvIsVolumeUpKey(key) || kotvIsVolumeDownKey(key)) {
      if (!_expanded) setState(() => _expanded = true);
      final up = kotvIsVolumeUpKey(key);
      final step = event is KeyRepeatEvent ? 2.0 : 5.0;
      unawaited(_applyVolume(vol + (up ? step : -step), persist: true));
      return KeyEventResult.handled;
    }

    // 未展开时左右用于焦点遍历；展开后左右调音量。
    if (kotvIsLeftKey(key) || kotvIsRightKey(key)) {
      if (!_expanded) {
        final dir = kotvIsLeftKey(key) ? TraversalDirection.left : TraversalDirection.right;
        return node.focusInDirection(dir) ? KeyEventResult.handled : KeyEventResult.ignored;
      }
      final up = kotvIsRightKey(key);
      final step = event is KeyRepeatEvent ? 2.0 : 5.0;
      unawaited(_applyVolume(vol + (up ? step : -step), persist: true));
      return KeyEventResult.handled;
    }

    if (kotvIsEnterKey(key)) {
      setState(() => _expanded = !_expanded);
      widget.onEngage?.call();
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

  IconData _iconFor(double vol) {
    if (vol <= 1) return Icons.volume_mute_rounded;
    if (vol < 35) return Icons.volume_down_rounded;
    return Icons.volume_up_rounded;
  }

  Color _ringColor(KotvPalette pal) => kotvFocusRingColor(pal, onDarkSurface: true);

  @override
  Widget build(BuildContext context) {
    final land = widget.compact;
    final ui = LayoutScale.grow(context);
    final iconSz = (land ? (widget.iconSize <= 34 ? 18.0 : 20.0) : (widget.iconSize <= 34 ? 18.0 : 22.0)) * ui;
    final box = widget.iconSize * ui;
    final ring = _ringColor(KotvPalette.of(context));
    return MouseRegion(
      onEnter: (_) => _setHover(true),
      onExit: (_) => _setHover(false),
      child: ListenableBuilder(
        listenable: widget.player,
        builder: (context, _) {
          final vol = widget.player.volume.clamp(1, 100).toDouble();
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedSize(
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOutCubic,
                alignment: Alignment.centerRight,
                child: _expanded
                    ? SizedBox(
                        width: widget.sliderWidth * ui,
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: land ? 2 : 3,
                            thumbShape: RoundSliderThumbShape(enabledThumbRadius: land ? 5 : 6),
                            overlayShape: RoundSliderOverlayShape(overlayRadius: land ? 10 : 12),
                            activeTrackColor: KotvColors.primary,
                            inactiveTrackColor: Colors.white24,
                            thumbColor: Colors.white,
                          ),
                          child: ExcludeFocus(
                            // 滑条只给鼠标和触控。FocusableActionDetector 会把 canRequestFocus 盖成 true，所以用 ExcludeFocus 挡住键盘焦点。
                            child: Slider(
                              value: vol,
                              min: 1,
                              max: 100,
                              onChanged: (v) => unawaited(_applyVolume(v, persist: false)),
                              onChangeEnd: (v) => unawaited(_applyVolume(v, persist: true)),
                            ),
                          ),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
              FocusableActionDetector(
                focusNode: _focus,
                onShowFocusHighlight: (v) {
                  if (_highlight == v) return;
                  setState(() => _highlight = v);
                },
                actions: <Type, Action<Intent>>{
                  ActivateIntent: CallbackAction<ActivateIntent>(
                    onInvoke: (_) {
                      setState(() => _expanded = !_expanded);
                      widget.onEngage?.call();
                      return null;
                    },
                  ),
                },
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    // 触控展开不 requestFocus，避免留下常亮焦点环。
                    setState(() => _expanded = !_expanded);
                    widget.onEngage?.call();
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    width: box,
                    height: box,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: kotvRing(_highlight) ? ring.withOpacity(0.22) : null,
                      border: Border.all(
                        color: kotvRing(_highlight) ? ring : Colors.transparent,
                        width: kotvRing(_highlight) ? 3 : 0,
                      ),
                      boxShadow: kotvRing(_highlight)
                          ? [BoxShadow(color: ring.withOpacity(0.55), blurRadius: 14, spreadRadius: 1)]
                          : null,
                    ),
                    child: Icon(_iconFor(vol), color: Colors.white, size: iconSz),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
