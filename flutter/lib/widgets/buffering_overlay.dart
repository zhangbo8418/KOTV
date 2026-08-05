import 'package:flutter/material.dart';

import '../player/kotv_playback.dart';

/// 缓冲中在画面中央显示转圈 + 网速（有速度时）。
class KotvBufferingOverlay extends StatelessWidget {
  const KotvBufferingOverlay({
    super.key,
    required this.player,
    this.force = false,
  });

  final KotvPlayback player;

  /// 额外强制显示（如起播加载文案阶段）。
  final bool force;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        if (!force && !player.buffering) return const SizedBox.shrink();
        // 缓冲时始终显示速率（含 0 KB/s），便于判断线路是否已死
        final speed = kotvFormatSpeed(player.networkSpeedBps, showZero: true);
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
      },
    );
  }
}
