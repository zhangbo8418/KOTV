import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../player/tv_remote_keys.dart';
import '../theme/kotv_palette.dart';
import '../theme/kotv_theme.dart';

/// 整行获焦。左右键按一格改数值，松手再提交；上下键把焦点交给相邻项。
///
/// 滑条本身不参与焦点，避免它把上下键也当成改数值。
class KotvStepSlider extends StatefulWidget {
  const KotvStepSlider({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onCommit,
    this.divisions = 20,
    this.format,
    this.onChanging,
    this.inline = false,
    this.inlineLabelWidth = 72,
    this.foreground,
    this.valueColor,
    this.padding,
    this.scrollIntoView = true,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String Function(double value)? format;
  final void Function(double value)? onChanging;
  final FutureOr<void> Function(double value) onCommit;

  /// 标签在滑条左侧。否则标签和当前值在滑条上方。
  final bool inline;
  final double inlineLabelWidth;
  final Color? foreground;
  final Color? valueColor;
  final EdgeInsetsGeometry? padding;
  final bool scrollIntoView;

  @override
  State<KotvStepSlider> createState() => _KotvStepSliderState();
}

class _KotvStepSliderState extends State<KotvStepSlider> {
  final _focus = FocusNode(debugLabel: 'kotv_step_slider');
  double? _pending;

  @override
  void initState() {
    super.initState();
    _focus.onKeyEvent = _onKey;
  }

  @override
  void dispose() {
    _focus.onKeyEvent = null;
    _focus.dispose();
    super.dispose();
  }

  double get _value => (_pending ?? widget.value).clamp(widget.min, widget.max);

  String _text(double v) {
    final fmt = widget.format;
    if (fmt != null) return fmt(v);
    if (widget.inline) return '${v.round()}';
    return v.toStringAsFixed(v == v.roundToDouble() ? 0 : 1);
  }

  void _commit(double v) {
    final result = widget.onCommit(v);
    if (result is Future) unawaited(result);
  }

  void _step(bool forward) {
    final changing = widget.onChanging;
    if (changing == null) return;
    final parts = widget.divisions <= 0 ? 1 : widget.divisions;
    final step = (widget.max - widget.min) / parts;
    final next = (_value + (forward ? step : -step)).clamp(widget.min, widget.max);
    setState(() => _pending = next);
    changing(next);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    if (kotvIsLeftKey(key) || kotvIsRightKey(key)) {
      if (widget.onChanging == null) return KeyEventResult.ignored;
      if (event is KeyDownEvent || event is KeyRepeatEvent) {
        _step(kotvIsRightKey(key));
      } else if (event is KeyUpEvent) {
        final v = _value;
        setState(() => _pending = null);
        _commit(v);
      }
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (kotvIsUpKey(key)) {
      return node.focusInDirection(TraversalDirection.up) ? KeyEventResult.handled : KeyEventResult.ignored;
    }
    if (kotvIsDownKey(key)) {
      return node.focusInDirection(TraversalDirection.down) ? KeyEventResult.handled : KeyEventResult.ignored;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final p = KotvPalette.of(context);
    final v = _value;
    final enabled = widget.onChanging != null;
    final labelColor = widget.foreground ?? (widget.inline ? Colors.white70 : p.fg);
    final numberColor = widget.valueColor ?? p.muted;
    final pad = widget.padding ??
        (widget.inline ? const EdgeInsets.fromLTRB(12, 0, 12, 4) : const EdgeInsets.fromLTRB(16, 8, 16, 4));

    Widget slider = Slider(
      value: v,
      min: widget.min,
      max: widget.max,
      divisions: widget.divisions,
      label: _text(v),
      onChanged: enabled
          ? (nv) {
              setState(() => _pending = nv);
              widget.onChanging!(nv);
            }
          : null,
      onChangeEnd: (nv) {
        setState(() => _pending = null);
        _commit(nv);
      },
    );
    if (!widget.inline) {
      slider = SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 3,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
        ),
        child: slider,
      );
    }
    slider = ExcludeFocus(child: slider);

    final Widget body;
    if (widget.inline) {
      body = Row(
        children: [
          if (widget.label.isNotEmpty)
            SizedBox(
              width: widget.inlineLabelWidth,
              child: Text(widget.label, style: TextStyle(color: labelColor, fontSize: 13)),
            ),
          Expanded(child: slider),
        ],
      );
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.label,
                  style: TextStyle(color: labelColor, fontSize: 14, fontWeight: FontWeight.w500),
                ),
              ),
              Text(_text(v), style: TextStyle(color: numberColor, fontSize: 13)),
            ],
          ),
          slider,
        ],
      );
    }

    return Padding(
      padding: pad,
      child: TvFocus(
        focusNode: _focus,
        borderRadius: 8,
        scrollIntoView: widget.scrollIntoView,
        child: body,
      ),
    );
  }
}
