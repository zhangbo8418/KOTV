import 'kotv_playback.dart';

/// 各播放器共用的**起播**画面守卫（抛错前尽量自愈；不负责播中卡顿）。
///
/// ## 原则
/// - **未在播的缓冲**：只等，不切播放器。
/// - **已在播却无稳定画面**：修轨 → 黑屏窗口 → [KotvSilentVideoException] → failover。
/// - **画面尺寸须稳住** [sizeSettleTimeout]，避免 demux 探头尺寸闪一下就当成功。
/// - **会话已死仍无画面**：抛错（不再静默 return，否则上层会当成开播成功）。
/// - **纯音频**：仅引擎确认无视轨时放行。
///
/// 不做「有尺寸但进度卡死」判定（静态封面音乐等）。
Future<void> kotvGuardSilentVideo({
  required bool Function() hasVideoSize,
  required bool Function() sessionAlive,
  required bool Function() isBuffering,
  bool Function()? isAudioOnly,
  bool Function()? hasVideoSource,
  Future<void> Function()? onFixVideoSource,
  Duration sourceFixTimeout = const Duration(seconds: 8),
  Duration blackScreenTimeout = const Duration(seconds: 8),
  Duration sessionDeadTimeout = const Duration(seconds: 2),
  /// 尺寸需连续保持多久才算真正出画（防元数据闪一下）。
  Duration sizeSettleTimeout = const Duration(milliseconds: 400),
  Duration tick = const Duration(milliseconds: 200),
}) async {
  DateTime? blackSince;
  DateTime? sourceWaitSince;
  DateTime? deadSince;
  DateTime? sizeSince;
  var sourceFixDone = false;
  var blackFixDone = false;

  while (true) {
    final now = DateTime.now();

    if (isAudioOnly?.call() == true) return;

    if (hasVideoSize()) {
      sizeSince ??= now;
      if (now.difference(sizeSince) >= sizeSettleTimeout) return;
      await Future<void>.delayed(tick);
      continue;
    }
    sizeSince = null;

    final alive = sessionAlive();

    // —— 仅「还在拉、尚未形成在播」才无限等 ——
    if (isBuffering() && !alive) {
      blackSince = null;
      sourceWaitSince = null;
      deadSince = null;
      await Future<void>.delayed(tick);
      continue;
    }

    // —— 会话已死：抛错，避免 open() 当成成功（播放中黑屏无声）——
    if (!alive) {
      blackSince = null;
      sourceWaitSince = null;
      deadSince ??= now;
      if (now.difference(deadSince) >= sessionDeadTimeout) {
        throw const KotvSilentVideoException('起播会话中断无画面');
      }
      await Future<void>.delayed(tick);
      continue;
    }
    deadSince = null;

    final sourceOk = hasVideoSource?.call() ?? true;
    if (!sourceOk) {
      blackSince = null;
      if (!sourceFixDone) {
        sourceFixDone = true;
        await onFixVideoSource?.call();
        if (isAudioOnly?.call() == true) return;
        sourceWaitSince = DateTime.now();
        await Future<void>.delayed(tick);
        continue;
      }
      sourceWaitSince ??= now;
      if (now.difference(sourceWaitSince) < sourceFixTimeout) {
        await Future<void>.delayed(tick);
        continue;
      }
      if (isAudioOnly?.call() == true) return;
      throw const KotvSilentVideoException('无可用视频源');
    }

    if (!sourceFixDone) {
      sourceFixDone = true;
      await onFixVideoSource?.call();
      if (isAudioOnly?.call() == true) return;
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
      if (isAudioOnly?.call() == true) return;
      blackSince = DateTime.now();
      await Future<void>.delayed(tick);
      continue;
    }

    if (isAudioOnly?.call() == true) return;
    throw const KotvSilentVideoException();
  }
}
