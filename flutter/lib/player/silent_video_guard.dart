import 'kotv_playback.dart';

/// 各播放器共用的开播画面守卫（阶梯判定，抛错前尽量自愈）。
///
/// 1. **缓冲中**：最多等 [bufferingTimeout]（默认 60s）
/// 2. **视源异常**（[hasVideoSource] 为 false）：调用 [onFixVideoSource] 一次，再等
///    [sourceFixTimeout]
/// 3. **有会话但仍无尺寸**（黑屏）：[blackScreenTimeout]（默认 5s）后再尝试一次
///    [onFixVideoSource]，仍无画面则抛 [KotvSilentVideoException]
///
/// 解码翻转 / 换播放器由上层 [KotvPlaybackFailover] 处理。
Future<void> kotvGuardSilentVideo({
  required bool Function() hasVideoSize,
  required bool Function() sessionAlive,
  required bool Function() isBuffering,
  /// 是否已挂上可用视频源/轨；`null` 表示引擎无法判断（视为有源）。
  bool Function()? hasVideoSource,
  Future<void> Function()? onFixVideoSource,
  Duration bufferingTimeout = const Duration(seconds: 60),
  Duration sourceFixTimeout = const Duration(seconds: 8),
  Duration blackScreenTimeout = const Duration(seconds: 5),
  Duration tick = const Duration(milliseconds: 200),
}) async {
  final started = DateTime.now();
  DateTime? blackSince;
  DateTime? sourceWaitSince;
  var sourceFixDone = false;
  var blackFixDone = false;

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
      sourceWaitSince = null;
      await Future<void>.delayed(tick);
      continue;
    }

    if (!sessionAlive()) {
      blackSince = null;
      sourceWaitSince = null;
      await Future<void>.delayed(tick);
      continue;
    }

    // —— 视源：无真实视频轨 / 未拿到视频元数据 ——
    final sourceOk = hasVideoSource?.call() ?? true;
    if (!sourceOk) {
      blackSince = null;
      if (!sourceFixDone) {
        sourceFixDone = true;
        await onFixVideoSource?.call();
        if (hasVideoSize()) return;
        sourceWaitSince = DateTime.now();
        await Future<void>.delayed(tick);
        continue;
      }
      sourceWaitSince ??= now;
      if (now.difference(sourceWaitSince) < sourceFixTimeout) {
        await Future<void>.delayed(tick);
        continue;
      }
      throw const KotvSilentVideoException('无可用视频源');
    }

    // —— 有源提示但仍无画面尺寸：黑屏窗口 ——
    if (!sourceFixDone) {
      // 进入黑屏前先修一次视源（MPV 重选轨；其它引擎再 play）。
      sourceFixDone = true;
      await onFixVideoSource?.call();
      if (hasVideoSize()) return;
      blackSince = DateTime.now();
      await Future<void>.delayed(tick);
      continue;
    }

    blackSince ??= now;
    if (now.difference(blackSince) < blackScreenTimeout) {
      await Future<void>.delayed(tick);
      continue;
    }

    if (!blackFixDone) {
      blackFixDone = true;
      await onFixVideoSource?.call();
      if (hasVideoSize()) return;
      blackSince = DateTime.now();
      await Future<void>.delayed(tick);
      continue;
    }

    throw const KotvSilentVideoException();
  }
}
