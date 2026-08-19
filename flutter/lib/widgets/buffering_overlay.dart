import 'dart:async';

import 'package:flutter/material.dart';

import '../player/kotv_playback.dart';
import '../player/kotv_traffic.dart';

/// 缓冲中在画面中央显示转圈 + 实时网速。
///
/// 浮层自己用 [KotvTraffic] 测速（引擎累计 / UID / 桌面网卡），
/// 与各播放器内部计数解耦；播放器 [KotvPlayback.networkSpeedBps] 仅作最后兜底。
class KotvBufferingOverlay extends StatefulWidget {
  const KotvBufferingOverlay({
    super.key,
    required this.player,
    this.force = false,
  });

  final KotvPlayback player;

  /// 额外强制显示（如起播加载文案阶段）。
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
    final want = widget.force || widget.player.buffering;
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
        // showProgress：出现时 reset，再按秒差分。
        KotvTraffic.reset();
        _trafficArmed = true;
        _speedBps = 0;
        unawaited(_pollTraffic());
      }
      _tick ??= Timer.periodic(const Duration(milliseconds: 1000), (_) {
        if (!mounted) return;
        final want = widget.force || widget.player.buffering;
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
    // 不铺半透明全屏、不加文字阴影：Hybrid Composition 的 SurfaceView
    // 会把半透明白字合成两遍，看起来像「缓冲中」重影。
    return IgnorePointer(
      child: Center(
        child: RepaintBoundary(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xE6111111),
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
