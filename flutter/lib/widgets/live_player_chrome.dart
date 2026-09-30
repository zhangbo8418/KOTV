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
import 'volume_control.dart';

/// 直播底栏控件：播放/暂停、投屏、迷你、全屏、播放器、软硬解、音量；（回看时含进度）。
class LiveCatchupChrome extends StatefulWidget {
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
    this.onScale,
    this.scaleLabel = '',
    this.onAcross,
    this.acrossOn = false,
    this.onInvert,
    this.invertOn = false,
    this.onFailSwitch,
    this.failSwitchOn = false,
    /// 竖屏/直播传 false：一键进沉浸全屏，不弹「铺满窗口」。
    this.offerFullscreenChoice,
    /// 已在真全屏时显示退出图标（回看底栏用）。
    this.fullscreenActive = false,
    /// 遥控菜单弹出时，自动焦点到播停键。
    this.autofocusPlay = false,
    this.playFocusNode,
    /// 任意控件操作后回调（重排隐藏计时）。
    this.onBump,
    /// 回看时显示时间与进度条；直播不画废进度。
    this.showSeek = false,
    this.onPersistSetting,
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
  final VoidCallback? onScale;
  final String scaleLabel;
  final VoidCallback? onAcross;
  final bool acrossOn;
  final VoidCallback? onInvert;
  final bool invertOn;
  final VoidCallback? onFailSwitch;
  final bool failSwitchOn;
  final bool? offerFullscreenChoice;
  final bool fullscreenActive;
  final bool autofocusPlay;
  final FocusNode? playFocusNode;
  final VoidCallback? onBump;
  final bool showSeek;
  final Future<void> Function(String key, String value)? onPersistSetting;

  @override
  State<LiveCatchupChrome> createState() => _LiveCatchupChromeState();
}

class _LiveCatchupChromeState extends State<LiveCatchupChrome> {
  final FocusNode _seekFocus = FocusNode(debugLabel: 'live_catchup_seek');

  @override
  void dispose() {
    _seekFocus.dispose();
    super.dispose();
  }

  void _tap(VoidCallback? action) {
    action?.call();
    widget.onBump?.call();
  }

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    final resolvedPlayerLabel = widget.playerLabel.trim().isEmpty
        ? flutterPlayerLabel(kotvDefaultLivePlayer())
        : widget.playerLabel;
    final land = KotvLayout.isLandscapeCompact(context);
    final iconSize = land ? 30.0 : 40.0;
    final compact = widget.miniActive || MediaQuery.sizeOf(context).width < 560 || land;
    return Material(
      color: widget.translucent ? const Color(0x660A0A12) : const Color(0xCC0A0A12),
      // 按钮/音量不挂 positionStream；仅时间与进度条随流重建（同点播内嵌底栏）。
      child: Padding(
        padding: EdgeInsets.fromLTRB(compact ? 4 : 10, land ? 2 : 4, compact ? 4 : 10, land ? 4 : 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                ListenableBuilder(
                  listenable: player,
                  builder: (context, _) {
                    return _act(
                      icon: player.playing ? Icons.pause : Icons.play_arrow,
                      tip: player.playing ? '暂停' : '播放',
                      compact: compact,
                      size: iconSize,
                      autofocus: widget.autofocusPlay,
                      focusNode: widget.playFocusNode,
                      onTap: () => _tap(() => player.playOrPause()),
                    );
                  },
                ),
                if (widget.onCast != null)
                  _act(
                    icon: Icons.cast,
                    tip: '投屏',
                    compact: compact,
                    size: iconSize,
                    onTap: () => _tap(widget.onCast),
                  ),
                if (widget.onMini != null)
                  _act(
                    icon: widget.miniActive ? Icons.close_fullscreen : Icons.picture_in_picture_alt,
                    tip: widget.miniActive ? '还原窗口' : '迷你桌面播放',
                    compact: compact,
                    size: iconSize,
                    onTap: () => _tap(widget.onMini),
                  ),
                if (widget.onExpand != null && !widget.miniActive)
                  (widget.offerFullscreenChoice == false)
                      ? _act(
                          icon: widget.fullscreenActive ? Icons.fullscreen_exit : Icons.fullscreen,
                          tip: widget.fullscreenActive ? '退出全屏' : '全屏',
                          compact: compact,
                          size: iconSize,
                          onTap: () => _tap(() => widget.onExpand!(KotvDesktopFullscreenKind.display)),
                        )
                      : KotvFullscreenExpandButton(
                          size: iconSize,
                          iconSize: iconSize <= 32 ? 16 : 22,
                          offerDisplayChoice: widget.offerFullscreenChoice,
                          onSelect: (kind) => _tap(() => widget.onExpand!(kind)),
                        ),
                if (!compact && widget.onPlayer != null)
                  _textAct(resolvedPlayerLabel, () => _tap(widget.onPlayer)),
                if (!compact && widget.onDecode != null)
                  _textAct(widget.decodeLabel, () => _tap(widget.onDecode)),
                if (widget.onScale != null)
                  _textAct(
                    widget.scaleLabel.trim().isEmpty ? '比例' : widget.scaleLabel,
                    () => _tap(widget.onScale),
                  ),
                if (widget.onAcross != null)
                  _textAct(widget.acrossOn ? '跨组开' : '跨组关', () => _tap(widget.onAcross)),
                if (widget.onInvert != null)
                  _textAct(widget.invertOn ? '反转开' : '反转关', () => _tap(widget.onInvert)),
                if (widget.onFailSwitch != null)
                  _textAct(widget.failSwitchOn ? '换线开' : '换线关', () => _tap(widget.onFailSwitch)),
                if (widget.showSeek) ...[
                  const SizedBox(width: 6),
                  StreamBuilder<Duration>(
                    stream: player.positionStream,
                    builder: (context, _) {
                      final pos = player.position;
                      final dur = player.duration;
                      return Text(
                        compact ? fmtPlayerTime(pos) : '${fmtPlayerTime(pos)} / ${fmtPlayerTime(dur)}',
                        style: TextStyle(color: Colors.white.withOpacity(0.75), fontSize: land ? 11 : (compact ? 11 : 12)),
                      );
                    },
                  ),
                ],
                const Spacer(),
                KotvVolumeControl(
                  player: player,
                  iconSize: iconSize,
                  sliderWidth: compact ? 72 : (land ? 90 : 110),
                  compact: compact,
                  onEngage: widget.onBump,
                  onPersist: widget.onPersistSetting == null
                      ? null
                      : (n) => widget.onPersistSetting!('playerVolume', '$n'),
                ),
              ],
            ),
            if (widget.showSeek)
              StreamBuilder<Duration>(
                stream: player.positionStream,
                builder: (context, _) {
                  final pos = player.position;
                  final dur = player.duration;
                  final total = dur.inMilliseconds <= 0 ? 1.0 : dur.inMilliseconds.toDouble();
                  return KotvSeekSlider(
                    player: player,
                    maxMs: total,
                    focusNode: _seekFocus,
                    secondaryMs: () {
                      if (total <= 0) return 0.0;
                      final p = pos.inMilliseconds.toDouble().clamp(0.0, total);
                      final b = player.buffered.inMilliseconds.toDouble().clamp(0.0, total);
                      return b < p ? p : b;
                    }(),
                    enabled: dur.inMilliseconds > 0,
                    onInteraction: widget.onBump,
                    theme: SliderTheme.of(context).copyWith(
                      trackHeight: land ? 2 : 3,
                      thumbShape: RoundSliderThumbShape(enabledThumbRadius: land ? 5 : 6),
                      overlayShape: RoundSliderOverlayShape(overlayRadius: land ? 10 : 12),
                      activeTrackColor: KotvColors.primary,
                      inactiveTrackColor: Colors.white24,
                      secondaryActiveTrackColor: Colors.white38,
                      thumbColor: Colors.white,
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _act({
    required IconData icon,
    required String tip,
    required bool compact,
    required VoidCallback onTap,
    double? size,
    bool autofocus = false,
    FocusNode? focusNode,
  }) {
    final sz = size ?? (compact ? 32.0 : 40.0);
    return Tooltip(
      message: tip,
      child: TvFocus(
        autofocus: autofocus,
        focusNode: focusNode,
        onPressed: onTap,
        borderRadius: 8,
        child: SizedBox(
          width: sz,
          height: sz,
          child: Icon(icon, color: Colors.white, size: sz <= 32 ? 16 : 22),
        ),
      ),
    );
  }

  Widget _textAct(String label, VoidCallback onTap) {
    return TvFocus(
      onPressed: onTap,
      borderRadius: 8,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
      ),
    );
  }
}
