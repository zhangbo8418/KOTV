import 'dart:async';

import 'package:flutter/material.dart';

import '../player/kotv_playback.dart';
import '../player/kotv_traffic.dart';

/// 缓冲中在画面中央显示转圈 + 实时网速。
///
/// Android：与 TV 相同，用 [KotvTraffic]（UID `TrafficStats`）测速，不依赖各引擎
/// 内部计数起播建基线为 0 的问题。其它平台仍读 [KotvPlayback.networkSpeedBps]。
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
    final speed = KotvTraffic.supported ? _speedBps : widget.player.networkSpeedBps;
    if (want == _visible && (!want || speed == _speedBps) && fromPlayer) {
      _ensureTicker(want);
      return;
    }
    setState(() {
      _visible = want;
      if (!KotvTraffic.supported) {
        _speedBps = speed < 0 ? 0 : speed;
      }
    });
    _ensureTicker(want);
  }

  void _ensureTicker(bool on) {
    if (on) {
      if (KotvTraffic.supported && !_trafficArmed) {
        // 对齐 TV showProgress：浮层出现时 reset，再按秒采差分。
        KotvTraffic.reset();
        _trafficArmed = true;
        _speedBps = 0;
        unawaited(_pollTraffic());
      }
      _tick ??= Timer.periodic(
        Duration(milliseconds: KotvTraffic.supported ? 1000 : 300),
        (_) {
          if (!mounted) return;
          final want = widget.force || widget.player.buffering;
          if (!want) {
            _sync(fromPlayer: true);
            return;
          }
          if (KotvTraffic.supported) {
            unawaited(_pollTraffic());
            return;
          }
          final speed = widget.player.networkSpeedBps;
          if (speed != _speedBps) {
            setState(() => _speedBps = speed < 0 ? 0 : speed);
          }
        },
      );
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
    final v = await KotvTraffic.sampleBps();
    if (!mounted || v < 0) return;
    if (v != _speedBps) {
      setState(() => _speedBps = v);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();
    final speed = kotvFormatSpeed(_speedBps, showZero: true);
    return IgnorePointer(
      child: ColoredBox(
        color: const Color(0x44000000),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 36,
                height: 36,
                child: CircularProgressIndicator(
                  color: Color(0xFFE53955),
                  strokeWidth: 3,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '缓冲中  $speed',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  shadows: [Shadow(color: Colors.black54, blurRadius: 6)],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
