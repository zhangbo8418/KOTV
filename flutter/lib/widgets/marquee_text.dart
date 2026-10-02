import 'package:flutter/material.dart';

/// 外层焦点或悬停时，内部超长文案跟着跑马灯。
class KotvMarqueeHost extends InheritedWidget {
  const KotvMarqueeHost({super.key, required this.active, required super.child});

  final bool active;

  static bool activeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<KotvMarqueeHost>()?.active ?? false;
  }

  @override
  bool updateShouldNotify(KotvMarqueeHost oldWidget) => active != oldWidget.active;
}

/// 单行文案：未溢出普通显示；溢出且 [active] 或外层焦点/悬停时水平跑马灯。
///
/// 未激活时用 ellipsis，避免列表里上百行同时动画。
class KotvMarqueeText extends StatefulWidget {
  const KotvMarqueeText(
    this.text, {
    super.key,
    required this.style,
    this.active = false,
    this.textAlign = TextAlign.left,
    this.blankGap = 48,
    this.velocity = 36,
    this.pause = const Duration(milliseconds: 900),
  });

  final String text;
  final TextStyle style;
  final bool active;
  final TextAlign textAlign;
  /// 滚完后与下一轮开头之间的空白。
  final double blankGap;
  /// 像素/秒。
  final double velocity;
  final Duration pause;

  @override
  State<KotvMarqueeText> createState() => _KotvMarqueeTextState();
}

class _KotvMarqueeTextState extends State<KotvMarqueeText> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(vsync: this);
  double _textW = 0;
  double _viewW = 0;
  bool _overflow = false;
  bool _wantRun = false;
  String? _measuredText;
  TextStyle? _measuredStyle;
  double? _measuredViewW;
  TextScaler? _measuredScaler;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant KotvMarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    final contentChanged = oldWidget.text != widget.text || oldWidget.style != widget.style;
    final animParamsChanged = oldWidget.active != widget.active ||
        oldWidget.velocity != widget.velocity ||
        oldWidget.pause != widget.pause ||
        oldWidget.blankGap != widget.blankGap;
    // 文案变了但父级宽度不变时，build 里旧逻辑不会重测 → 超长有时不滚。
    if (contentChanged && _viewW > 1) {
      _remeasure(_viewW, MediaQuery.maybeTextScalerOf(context) ?? TextScaler.noScaling);
    }
    if (contentChanged || animParamsChanged) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncAnim();
      });
    }
  }

  TextStyle _effectiveStyle() {
    final base = DefaultTextStyle.of(context).style;
    final merged = base.merge(widget.style);
    if (widget.style.fontFamilyFallback != null && widget.style.fontFamilyFallback!.isNotEmpty) {
      return merged;
    }
    if (base.fontFamilyFallback != null && base.fontFamilyFallback!.isNotEmpty) {
      return merged.copyWith(fontFamilyFallback: base.fontFamilyFallback);
    }
    return merged;
  }

  double _measure(String text, TextStyle style, TextScaler scaler) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    return tp.width;
  }

  bool _remeasure(double maxW, TextScaler scaler) {
    if (!maxW.isFinite || maxW <= 0) return false;
    final style = _effectiveStyle();
    final same = _measuredText == widget.text &&
        _measuredStyle == style &&
        _measuredScaler == scaler &&
        _measuredViewW != null &&
        (_measuredViewW! - maxW).abs() <= 0.5;
    if (same) return false;

    final tw = _measure(widget.text, style, scaler);
    final overflow = tw > maxW + 0.5;
    _viewW = maxW;
    _textW = tw;
    _overflow = overflow;
    _measuredText = widget.text;
    _measuredStyle = style;
    _measuredViewW = maxW;
    _measuredScaler = scaler;
    return true;
  }

  void _syncAnim() {
    final shouldRun = _wantRun && _overflow && _viewW > 1 && _textW > _viewW;
    if (!shouldRun) {
      if (_ctrl.isAnimating) _ctrl.stop();
      _ctrl.value = 0;
      return;
    }
    final travel = _textW + widget.blankGap;
    final seconds = (travel / widget.velocity.clamp(12.0, 120.0)).clamp(2.0, 40.0);
    final total = Duration(milliseconds: (seconds * 1000).round()) + widget.pause;
    final durationChanged = _ctrl.duration != total;
    if (durationChanged) {
      _ctrl.duration = total;
    }
    if (!_ctrl.isAnimating) {
      _ctrl.repeat();
    } else if (durationChanged) {
      _ctrl
        ..stop()
        ..reset()
        ..repeat();
    }
  }

  @override
  Widget build(BuildContext context) {
    final want = widget.active || KotvMarqueeHost.activeOf(context);
    if (want != _wantRun) {
      _wantRun = want;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncAnim();
      });
    }
    final scaler = MediaQuery.textScalerOf(context);
    final style = _effectiveStyle();
    return LayoutBuilder(
      builder: (context, c) {
        final maxW = c.maxWidth;
        if (maxW.isFinite && maxW > 0) {
          final changed = _remeasure(maxW, scaler);
          if (changed) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _syncAnim();
            });
          }
        }

        if (!_overflow || !_wantRun) {
          return SizedBox(
            width: maxW.isFinite && maxW > 0 ? maxW : null,
            child: Text(
              widget.text,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              textAlign: widget.textAlign,
              style: style,
            ),
          );
        }

        final durMs = _ctrl.duration?.inMilliseconds ?? 0;
        // duration 尚未由 _syncAnim 写好时先静态显示，避免 pauseFrac→∞ 导致永远不滚。
        if (durMs <= 0) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _syncAnim();
          });
          return SizedBox(
            width: maxW,
            child: ClipRect(
              child: Text(
                widget.text,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.visible,
                style: style,
              ),
            ),
          );
        }

        final pauseFrac = (widget.pause.inMilliseconds / durMs).clamp(0.0, 0.9);
        return SizedBox(
          width: maxW,
          child: ClipRect(
            child: AnimatedBuilder(
              animation: _ctrl,
              builder: (context, _) {
                final t = _ctrl.value;
                final progress = t <= pauseFrac ? 0.0 : (t - pauseFrac) / (1 - pauseFrac).clamp(0.01, 1.0);
                final dx = -progress * (_textW + widget.blankGap);
                return Stack(
                  clipBehavior: Clip.hardEdge,
                  children: [
                    Transform.translate(
                      offset: Offset(dx, 0),
                      child: Text(
                        widget.text,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.visible,
                        style: style,
                      ),
                    ),
                    Transform.translate(
                      offset: Offset(dx + _textW + widget.blankGap, 0),
                      child: Text(
                        widget.text,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.visible,
                        style: style,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }
}
