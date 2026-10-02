import '../desktop/mini_player_window.dart';
import '../screens/detail_screen.dart';
import '../screens/live_screen.dart';

/// 卸掉详情和直播里正在出声的播放器。
/// [keepMini] 为 true 且悬浮小窗开着时不动，小窗是唯一可以留在后台的那一个。
Future<void> kotvStopBackgroundPlayback({bool keepMini = false}) async {
  if (keepMini && MiniPlayerWindow.active) return;
  await DetailScreen.prepareLeave();
  await LiveScreen.prepareLeave();
}
