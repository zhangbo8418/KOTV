import 'kotv_playback.dart';

/// 各播放器共用的「开播无画面」守卫。
///
/// 判定：轮询 [hasVideoSize]；超时后若 [sessionAlive] 仍为真则抛
/// [KotvSilentVideoException]。可选 [onStillInvisible]（如 MPV 重选轨）后再等一轮。
Future<void> kotvGuardSilentVideo({
  required bool Function() hasVideoSize,
  required bool Function() sessionAlive,
  int waitTicks = 40,
  int afterHookTicks = 15,
  Duration tick = const Duration(milliseconds: 200),
  Future<void> Function()? onStillInvisible,
}) async {
  for (var i = 0; i < waitTicks; i++) {
    if (hasVideoSize()) return;
    await Future<void>.delayed(tick);
  }
  if (hasVideoSize()) return;

  if (onStillInvisible != null) {
    await onStillInvisible();
    for (var i = 0; i < afterHookTicks; i++) {
      if (hasVideoSize()) return;
      await Future<void>.delayed(tick);
    }
    if (hasVideoSize()) return;
  }

  if (sessionAlive()) {
    throw const KotvSilentVideoException();
  }
}
