import 'package:flutter/material.dart';

import '../player/kotv_playback.dart';
import '../theme/kotv_theme.dart';

/// 进度条：拖动只改 UI，松手才 [KotvPlayback.seek]。
///
/// seek 完成前钉住目标位置，避免播放器短暂回报 0 导致进度条闪回开头。
class KotvSeekSlider extends StatefulWidget {
  const KotvSeekSlider({
    super.key,
    required this.player,
    required this.maxMs,
    this.secondaryMs,
    this.enabled = true,
    this.onInteraction,
    this.theme,
  });

  final KotvPlayback player;
  final double maxMs;
  final double? secondaryMs;
  final bool enabled;
  final VoidCallback? onInteraction;
  final SliderThemeData? theme;

  @override
  State<KotvSeekSlider> createState() => _KotvSeekSliderState();
}

class _KotvSeekSliderState extends State<KotvSeekSlider> {
  double? _scrubMs;
  double? _pendingSeekMs;

  @override
  void initState() {
    super.initState();
    widget.player.addListener(_onPlayer);
  }

  @override
  void didUpdateWidget(covariant KotvSeekSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      oldWidget.player.removeListener(_onPlayer);
      widget.player.addListener(_onPlayer);
      _scrubMs = null;
      _pendingSeekMs = null;
    }
  }

  @override
  void dispose() {
    widget.player.removeListener(_onPlayer);
    super.dispose();
  }

  void _onPlayer() {
    final pending = _pendingSeekMs;
    if (pending == null || !mounted) return;
    final max = widget.maxMs <= 0 ? 1.0 : widget.maxMs;
    final live = widget.player.position.inMilliseconds.toDouble().clamp(0.0, max);
    if ((live - pending).abs() <= 1500) {
      setState(() => _pendingSeekMs = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final max = widget.maxMs <= 0 ? 1.0 : widget.maxMs;
    final live = widget.player.position.inMilliseconds.toDouble().clamp(0.0, max);
    final value = (_scrubMs ?? _pendingSeekMs ?? live).clamp(0.0, max);
    final secondary = (widget.secondaryMs ?? live).clamp(0.0, max);

    final slider = Slider(
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

    final themed = widget.theme;
    if (themed != null) {
      return SliderTheme(data: themed, child: slider);
    }
    return SliderTheme(
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
  }
}
