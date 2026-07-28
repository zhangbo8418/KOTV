import 'dart:async';

import 'package:flutter/material.dart';

/// 迷你窗：画面铺满；控件半透明叠底，鼠标移入显示、移出隐藏。
class MiniHoverShell extends StatefulWidget {
  const MiniHoverShell({
    super.key,
    required this.video,
    required this.chrome,
    this.borderRadius = 10,
  });

  final Widget video;
  final Widget chrome;
  final double borderRadius;

  @override
  State<MiniHoverShell> createState() => _MiniHoverShellState();
}

class _MiniHoverShellState extends State<MiniHoverShell> {
  bool _show = false;
  Timer? _hide;

  void _enter() {
    _hide?.cancel();
    if (!_show) setState(() => _show = true);
  }

  void _leave() {
    _hide?.cancel();
    _hide = Timer(const Duration(milliseconds: 450), () {
      if (mounted) setState(() => _show = false);
    });
  }

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: MouseRegion(
        onEnter: (_) => _enter(),
        onExit: (_) => _leave(),
        onHover: (_) => _enter(),
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: const Color(0xFF0A0A12), child: widget.video),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: IgnorePointer(
                ignoring: !_show,
                child: AnimatedOpacity(
                  opacity: _show ? 1 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withOpacity(0),
                          Colors.black.withOpacity(0.55),
                        ],
                      ),
                    ),
                    child: widget.chrome,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
