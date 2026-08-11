import 'kotv_playback.dart';

/// 各播放器共用的「开播无画面」守卫。
///
/// - **缓冲中**：最多等 [bufferingTimeout]（默认 60s），避免慢源误切播放器
/// - **非缓冲但仍无尺寸**（有声无画等）：[blackScreenTimeout]（默认 5s）后抛
///   [KotvSilentVideoException]
///
/// 可选 [onStillInvisible]（如 MPV 重选轨）在首次黑屏超时前执行一次，再给一轮黑屏窗口。
Future<void> kotvGuardSilentVideo({
  required bool Function() hasVideoSize,
  required bool Function() sessionAlive,
  required bool Function() isBuffering,
  Duration bufferingTimeout = const Duration(seconds: 60),
  Duration blackScreenTimeout = const Duration(seconds: 5),
  Duration tick = const Duration(milliseconds: 200),
  Future<void> Function()? onStillInvisible,
}) async {
  final started = DateTime.now();
  DateTime? blackSince;
  var hookDone = false;

  while (true) {
    if (hasVideoSize()) return;

    final now = DateTime.now();
    if (now.difference(started) >= bufferingTimeout) {
      if (sessionAlive() || isBuffering()) {
        throw const KotvSilentVideoException('缓冲超时无画面');
      }
      return;
    }

    if (isBuffering()) {
      blackSince = null;
      await Future<void>.delayed(tick);
      continue;
    }

    if (!sessionAlive()) {
      blackSince = null;
      await Future<void>.delayed(tick);
      continue;
    }

    blackSince ??= now;
    if (now.difference(blackSince) < blackScreenTimeout) {
      await Future<void>.delayed(tick);
      continue;
    }

    if (onStillInvisible != null && !hookDone) {
      hookDone = true;
      await onStillInvisible();
      if (hasVideoSize()) return;
      blackSince = DateTime.now();
      await Future<void>.delayed(tick);
      continue;
    }

    throw const KotvSilentVideoException();
  }
}
