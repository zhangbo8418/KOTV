import '../desktop/mini_player_window.dart';
import '../screens/detail_screen.dart';
import '../screens/live_screen.dart';

/// 卸掉详情和直播里正在出声的播放器。
/// [keepMini] 为 true 且悬浮小窗开着时不动，小窗是唯一可以留在后台的那一个。
/// [leaveLive] 为 false 时只停点播（直播同页选源勿卸 PlatformView）。
Future<void> kotvStopBackgroundPlayback({
  bool keepMini = false,
  bool leaveLive = true,
}) async {
  if (keepMini && MiniPlayerWindow.active) return;
  await DetailScreen.prepareLeave();
  if (leaveLive) await LiveScreen.prepareLeave();
}
