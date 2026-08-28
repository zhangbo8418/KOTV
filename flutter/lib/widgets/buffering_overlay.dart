import 'dart:async';

import 'package:flutter/material.dart';

import '../player/kotv_playback.dart';
import '../player/kotv_traffic.dart';

/// 缓冲中在**播放器 Stack 内**居中显示转圈 + 实时网速（必须叠在视频区域，不能挂全局 Overlay）。
///
/// 浮层用 [KotvTraffic] 测速；Hybrid Composition 下用不透明底避免 SurfaceView 叠字重影。
class KotvBufferingOverlay extends StatefulWidget {
  const KotvBufferingOverlay({
    super.key,
    required this.player,
    this.force = false,
  });

  final KotvPlayback player;
  final bool force;

  @override
  State<KotvBufferingOverlay> createState() => _KotvBufferingOverlayState();
}

class _KotvBufferingOverlayState extends State<KotvBufferingOverlay> {
  Timer? _tick;
  int _speedBps = 0;
  bool _visible = false;
  bool _trafficArmed = false;

  @override
  void initState() {
    super.initState();
    widget.player.addListener(_onPlayer);
    _sync(fromPlayer: true);
  }

  @override
  void didUpdateWidget(covariant KotvBufferingOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      oldWidget.player.removeListener(_onPlayer);
      widget.player.addListener(_onPlayer);
      _sync(fromPlayer: true);
    } else if (oldWidget.force != widget.force) {
      _sync(fromPlayer: true);
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    widget.player.removeListener(_onPlayer);
    if (_trafficArmed) {
      KotvTraffic.reset();
      _trafficArmed = false;
    }
    super.dispose();
  }

  void _onPlayer() => _sync(fromPlayer: true);

  void _sync({required bool fromPlayer}) {
    final want = widget.force || widget.player.stalling;
    if (want == _visible && fromPlayer) {
      _ensureTicker(want);
      return;
    }
    setState(() => _visible = want);
    _ensureTicker(want);
  }

  void _ensureTicker(bool on) {
    if (on) {
      if (!_trafficArmed) {
        KotvTraffic.reset();
        _trafficArmed = true;
        _speedBps = 0;
        unawaited(_pollTraffic());
      }
      _tick ??= Timer.periodic(const Duration(milliseconds: 1000), (_) {
        if (!mounted) return;
        final want = widget.force || widget.player.stalling;
        if (!want) {
          _sync(fromPlayer: true);
          return;
        }
        unawaited(_pollTraffic());
      });
    } else {
      _tick?.cancel();
      _tick = null;
      if (_trafficArmed) {
        KotvTraffic.reset();
        _trafficArmed = false;
      }
    }
  }

  Future<void> _pollTraffic() async {
    final v = await KotvTraffic.sampleBps(
      playerFallbackBps: widget.player.networkSpeedBps,
    );
    if (!mounted) return;
    if (v != _speedBps) {
      setState(() => _speedBps = v);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();
    final speed = kotvFormatSpeed(_speedBps, showZero: true);
    return IgnorePointer(
      child: Center(
        child: RepaintBoundary(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xFF111111),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(
                      color: Color(0xFFE53955),
                      strokeWidth: 3,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '缓冲中  $speed',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      height: 1.2,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
