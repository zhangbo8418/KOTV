import 'dart:async';

import 'package:flutter/material.dart';

import '../nav/kotv_page.dart';
import '../player/kotv_playback.dart';

/// 迷你窗 / 全窗口：画面铺满；鼠标移入露出底栏，播放中超时收起；暂停时保持底栏。
class MiniHoverShell extends StatefulWidget {
  const MiniHoverShell({
    super.key,
    required this.video,
    required this.chrome,
    this.player,
    this.borderRadius = 10,
  });

  final Widget video;
  final Widget chrome;
  final KotvPlayback? player;
  final double borderRadius;

  @override
  State<MiniHoverShell> createState() => _MiniHoverShellState();
}

class _MiniHoverShellState extends State<MiniHoverShell> {
  bool _show = false;
  bool _hovering = false;
  Timer? _hide;

  @override
  void initState() {
    super.initState();
    widget.player?.addListener(_onPlayer);
    if (_paused) _show = true;
  }

  @override
  void didUpdateWidget(covariant MiniHoverShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      oldWidget.player?.removeListener(_onPlayer);
      widget.player?.addListener(_onPlayer);
      _sync();
    }
  }

  @override
  void dispose() {
    _hide?.cancel();
    widget.player?.removeListener(_onPlayer);
    super.dispose();
  }

  void _onPlayer() => _sync();

  bool get _paused => widget.player != null && !widget.player!.playing;

  void _enter() {
    _hovering = true;
    _sync();
  }

  void _leave() {
    _hovering = false;
    _sync();
  }

  void _sync() {
    if (!mounted) return;
    _hide?.cancel();
    if (_paused) {
      if (!_show) setState(() => _show = true);
      return;
    }
    if (_hovering) {
      if (!_show) setState(() => _show = true);
      _hide = Timer(const Duration(seconds: 2), () {
        if (!mounted || _paused) return;
        setState(() => _show = false);
      });
      return;
    }
    if (_show) setState(() => _show = false);
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: MouseRegion(
        onEnter: (_) => _enter(),
        onExit: (_) => _leave(),
        onHover: (_) => _enter(),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onSecondaryTap: () => kotvHandleAppBack?.call(),
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
      ),
    );
  }
}
