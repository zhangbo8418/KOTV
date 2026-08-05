import 'package:flutter/material.dart';

import '../player/kotv_playback.dart';
import '../theme/kotv_theme.dart';
import 'vod_player_chrome.dart';

/// 直播底栏控件：播放/暂停、投屏、迷你、全屏、播放器、软硬解、音量；（回看时含进度）。
class LiveCatchupChrome extends StatelessWidget {
  const LiveCatchupChrome({
    super.key,
    required this.player,
    this.miniActive = false,
    this.translucent = false,
    this.onCast,
    this.onMini,
    this.onExpand,
    this.onPlayer,
    this.onDecode,
    this.playerLabel = '内置 MPV',
    this.decodeLabel = '自动',
  });

  final KotvPlayback player;
  final bool miniActive;
  final bool translucent;
  final VoidCallback? onCast;
  final VoidCallback? onMini;
  /// 全屏（移动端播放器控件需要）。
  final VoidCallback? onExpand;
  final VoidCallback? onPlayer;
  final VoidCallback? onDecode;
  final String playerLabel;
  final String decodeLabel;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: translucent ? const Color(0x660A0A12) : const Color(0xCC0A0A12),
      child: StreamBuilder(
        stream: player.positionStream,
        builder: (context, _) {
          final pos = player.position;
          final dur = player.duration;
          final total = dur.inMilliseconds <= 0 ? 1.0 : dur.inMilliseconds.toDouble();
          final vol = player.volume.clamp(0, 100).toDouble();
          final compact = miniActive || MediaQuery.sizeOf(context).width < 560;
          return Padding(
            padding: EdgeInsets.fromLTRB(compact ? 4 : 10, 4, compact ? 4 : 10, 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    _act(
                      icon: player.playing ? Icons.pause : Icons.play_arrow,
                      tip: player.playing ? '暂停' : '播放',
                      compact: compact,
                      onTap: () => player.playOrPause(),
                    ),
                    if (onCast != null)
                      _act(icon: Icons.cast, tip: '投屏', compact: compact, onTap: onCast!),
                    if (onMini != null)
                      _act(
                        icon: miniActive ? Icons.close_fullscreen : Icons.picture_in_picture_alt,
                        tip: miniActive ? '还原窗口' : '迷你桌面播放',
                        compact: compact,
                        onTap: onMini!,
                      ),
                    if (onExpand != null && !miniActive)
                      _act(
                        icon: Icons.fullscreen,
                        tip: '全屏',
                        compact: compact,
                        onTap: onExpand!,
                      ),
                    if (!compact && onPlayer != null)
                      _textAct(playerLabel, onPlayer!),
                    if (!compact && onDecode != null)
                      _textAct(decodeLabel, onDecode!),
                    const SizedBox(width: 6),
                    Text(
                      compact ? fmtPlayerTime(pos) : '${fmtPlayerTime(pos)} / ${fmtPlayerTime(dur)}',
                      style: TextStyle(color: Colors.white.withOpacity(0.75), fontSize: compact ? 11 : 12),
                    ),
                    const Spacer(),
                    if (!compact)
                      Text('音量', style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 12)),
                    SizedBox(
                      width: compact ? 72 : 110,
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 3,
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                          overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                          activeTrackColor: KotvColors.primary,
                          inactiveTrackColor: Colors.white24,
                          thumbColor: Colors.white,
                        ),
                        child: Slider(
                          value: vol,
                          max: 100,
                          onChanged: (v) => player.setVolume(v),
                        ),
                      ),
                    ),
                  ],
                ),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                    activeTrackColor: KotvColors.primary,
                    inactiveTrackColor: Colors.white24,
                    secondaryActiveTrackColor: Colors.white38,
                    thumbColor: Colors.white,
                  ),
                  child: Slider(
                    value: pos.inMilliseconds.clamp(0, total.toInt()).toDouble(),
                    secondaryTrackValue: () {
                      final p = pos.inMilliseconds.toDouble();
                      final b = player.buffered.inMilliseconds.toDouble();
                      return b.clamp(p, total);
                    }(),
                    max: total,
                    onChanged: dur.inMilliseconds <= 0
                        ? null
                        : (v) => player.seek(Duration(milliseconds: v.round())),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _act({
    required IconData icon,
    required String tip,
    required bool compact,
    required VoidCallback onTap,
  }) {
    final size = compact ? 32.0 : 40.0;
    return Tooltip(
      message: tip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, color: Colors.white, size: compact ? 18 : 22),
        ),
      ),
    );
  }

  Widget _textAct(String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
      ),
    );
  }
}
