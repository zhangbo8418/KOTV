import 'package:flutter/material.dart';

import '../player/fullscreen_mode.dart';
import '../player/kotv_platform.dart';
import '../player/kotv_playback.dart';
import '../remote/remote_bridge.dart';
import '../theme/kotv_theme.dart';
import '../theme/layout_scale.dart';
import 'fullscreen_expand_button.dart';
import 'seek_slider.dart';
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
    this.playerLabel = '',
    this.decodeLabel = '自动',
    /// 竖屏/直播传 false：一键进沉浸全屏，不弹「铺满窗口」。
    this.offerFullscreenChoice,
    /// 已在真全屏时显示退出图标（回看底栏用）。
    this.fullscreenActive = false,
  });

  final KotvPlayback player;
  final bool miniActive;
  final bool translucent;
  final VoidCallback? onCast;
  final VoidCallback? onMini;
  /// 全屏：移动端直接进入；桌面在图标上弹出抽屉选项。
  final ValueChanged<KotvDesktopFullscreenKind>? onExpand;
  final VoidCallback? onPlayer;
  final VoidCallback? onDecode;
  final String playerLabel;
  final String decodeLabel;
  final bool? offerFullscreenChoice;
  final bool fullscreenActive;

  @override
  Widget build(BuildContext context) {
    final resolvedPlayerLabel =
        playerLabel.trim().isEmpty ? flutterPlayerLabel(kotvDefaultLivePlayer()) : playerLabel;
    final land = KotvLayout.isLandscapeCompact(context);
    final iconSize = land ? 30.0 : 40.0;
    return Material(
      color: translucent ? const Color(0x660A0A12) : const Color(0xCC0A0A12),
      child: StreamBuilder(
        stream: player.positionStream,
        builder: (context, _) {
          final pos = player.position;
          final dur = player.duration;
          final total = dur.inMilliseconds <= 0 ? 1.0 : dur.inMilliseconds.toDouble();
          final vol = player.volume.clamp(0, 100).toDouble();
          final compact = miniActive || MediaQuery.sizeOf(context).width < 560 || land;
          return Padding(
            padding: EdgeInsets.fromLTRB(compact ? 4 : 10, land ? 2 : 4, compact ? 4 : 10, land ? 4 : 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    _act(
                      icon: player.playing ? Icons.pause : Icons.play_arrow,
                      tip: player.playing ? '暂停' : '播放',
                      compact: compact,
                      size: iconSize,
                      onTap: () => player.playOrPause(),
                    ),
                    if (onCast != null)
                      _act(icon: Icons.cast, tip: '投屏', compact: compact, size: iconSize, onTap: onCast!),
                    if (onMini != null)
                      _act(
                        icon: miniActive ? Icons.close_fullscreen : Icons.picture_in_picture_alt,
                        tip: miniActive ? '还原窗口' : '迷你桌面播放',
                        compact: compact,
                        size: iconSize,
                        onTap: onMini!,
                      ),
                    if (onExpand != null && !miniActive)
                      (offerFullscreenChoice == false)
                          ? _act(
                              icon: fullscreenActive ? Icons.fullscreen_exit : Icons.fullscreen,
                              tip: fullscreenActive ? '退出全屏' : '全屏',
                              compact: compact,
                              size: iconSize,
                              onTap: () => onExpand!(KotvDesktopFullscreenKind.display),
                            )
                          : KotvFullscreenExpandButton(
                              size: iconSize,
                              iconSize: iconSize <= 32 ? 16 : 22,
                              offerDisplayChoice: offerFullscreenChoice,
                              onSelect: onExpand!,
                            ),
                    if (!compact && onPlayer != null)
                      _textAct(resolvedPlayerLabel, onPlayer!),
                    if (!compact && onDecode != null)
                      _textAct(decodeLabel, onDecode!),
                    const SizedBox(width: 6),
                    Text(
                      compact ? fmtPlayerTime(pos) : '${fmtPlayerTime(pos)} / ${fmtPlayerTime(dur)}',
                      style: TextStyle(color: Colors.white.withOpacity(0.75), fontSize: land ? 11 : (compact ? 11 : 12)),
                    ),
                    const Spacer(),
                    if (!compact)
                      Text('音量', style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: land ? 11 : 12)),
                    SizedBox(
                      width: compact ? 72 : (land ? 90 : 110),
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: land ? 2 : 3,
                          thumbShape: RoundSliderThumbShape(enabledThumbRadius: land ? 5 : 6),
                          overlayShape: RoundSliderOverlayShape(overlayRadius: land ? 10 : 12),
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
                KotvSeekSlider(
                  player: player,
                  maxMs: total,
                  secondaryMs: () {
                    if (total <= 0) return 0.0;
                    final p = pos.inMilliseconds.toDouble().clamp(0.0, total);
                    final b = player.buffered.inMilliseconds.toDouble().clamp(0.0, total);
                    return b < p ? p : b;
                  }(),
                  enabled: dur.inMilliseconds > 0,
                  theme: SliderTheme.of(context).copyWith(
                    trackHeight: land ? 2 : 3,
                    thumbShape: RoundSliderThumbShape(enabledThumbRadius: land ? 5 : 6),
                    overlayShape: RoundSliderOverlayShape(overlayRadius: land ? 10 : 12),
                    activeTrackColor: KotvColors.primary,
                    inactiveTrackColor: Colors.white24,
                    secondaryActiveTrackColor: Colors.white38,
                    thumbColor: Colors.white,
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
    double? size,
  }) {
    final sz = size ?? (compact ? 32.0 : 40.0);
    return Tooltip(
      message: tip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: sz,
          height: sz,
          child: Icon(icon, color: Colors.white, size: sz <= 32 ? 16 : 22),
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
