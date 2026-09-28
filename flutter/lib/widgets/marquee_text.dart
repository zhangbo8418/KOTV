import 'package:flutter/material.dart';

/// 单行文案：未溢出普通显示；溢出且 [active] 时水平跑马灯。
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

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant KotvMarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        oldWidget.style != widget.style ||
        oldWidget.active != widget.active ||
        oldWidget.velocity != widget.velocity ||
        oldWidget.pause != widget.pause ||
        oldWidget.blankGap != widget.blankGap) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncAnim();
      });
    }
  }

  double _measure(String text, TextStyle style) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    return tp.width;
  }

  void _syncAnim() {
    final shouldRun = widget.active && _overflow && _viewW > 1 && _textW > _viewW;
    if (!shouldRun) {
      if (_ctrl.isAnimating) _ctrl.stop();
      _ctrl.value = 0;
      return;
    }
    final travel = _textW + widget.blankGap;
    final seconds = (travel / widget.velocity.clamp(12.0, 120.0)).clamp(2.0, 40.0);
    final total = Duration(milliseconds: (seconds * 1000).round()) + widget.pause;
    if (_ctrl.duration != total) {
      _ctrl.duration = total;
    }
    if (!_ctrl.isAnimating) {
      _ctrl.repeat();
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final maxW = c.maxWidth;
        if (maxW.isFinite && maxW > 0 && (maxW - _viewW).abs() > 0.5) {
          _viewW = maxW;
          _textW = _measure(widget.text, widget.style);
          _overflow = _textW > maxW + 0.5;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _syncAnim();
          });
        }

        if (!_overflow || !widget.active) {
          return SizedBox(
            width: maxW.isFinite && maxW > 0 ? maxW : null,
            child: Text(
              widget.text,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              textAlign: widget.textAlign,
              style: widget.style,
            ),
          );
        }

        final pauseFrac = widget.pause.inMilliseconds /
            (_ctrl.duration?.inMilliseconds.clamp(1, 1 << 30) ?? 1);
        return SizedBox(
          width: maxW,
          child: ClipRect(
            child: AnimatedBuilder(
              animation: _ctrl,
              builder: (context, _) {
                final t = _ctrl.value;
                // 前 pauseFrac 停在起点，其后线性滚出。
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
                        style: widget.style,
                      ),
                    ),
                    Transform.translate(
                      offset: Offset(dx + _textW + widget.blankGap, 0),
                      child: Text(
                        widget.text,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.visible,
                        style: widget.style,
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
