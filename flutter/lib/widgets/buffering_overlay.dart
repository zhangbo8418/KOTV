import 'dart:async';

import 'package:flutter/material.dart';

import '../player/kotv_playback.dart';
import '../player/kotv_traffic.dart';

/// 缓冲中在**播放器 Stack 内**居中显示转圈 + 实时网速（必须叠在视频区域，不能挂全局 Overlay）。
///
/// Exo SurfaceView：改由原生宿主画浮层（Hybrid Composition 上 Flutter 叠字会重影）。
/// 其它后端（MPV/FVP/Texture）仍用本组件 Flutter 浮层。
/// 浮层用 [KotvTraffic] 测速。
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
  bool? _lastNativeVisible;
  String? _lastNativeText;

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
    if (widget.player.preferNativeBufferingOverlay) {
      _lastNativeVisible = null;
      unawaited(widget.player.setNativeBufferingOverlay(visible: false, text: ''));
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

  void _syncNative(bool visible, String label) {
    if (!widget.player.preferNativeBufferingOverlay) return;
    if (_lastNativeVisible == visible && _lastNativeText == label) return;
    _lastNativeVisible = visible;
    _lastNativeText = label;
    unawaited(widget.player.setNativeBufferingOverlay(visible: visible, text: label));
  }

  @override
  Widget build(BuildContext context) {
    final speed = kotvFormatSpeed(_speedBps, showZero: true);
    final label = '缓冲中  $speed';
    // Exo Surface：缓冲 UI 画在原生宿主，避免 Hybrid Composition 叠字重影。
    if (widget.player.preferNativeBufferingOverlay) {
      _syncNative(_visible, label);
      return const SizedBox.shrink();
    }
    if (!_visible) return const SizedBox.shrink();
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
                    label,
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
