import 'kotv_playback.dart';

/// 各播放器共用的**起播**画面守卫（抛错前尽量自愈；不负责播中卡顿）。
///
/// ## 原则
/// - **未在播的缓冲**：只等，不切播放器。
/// - **已在播却无稳定画面**：修轨 → 黑屏窗口 → failover。
/// - **尺寸须稳住** [sizeSettleTimeout]。
/// - **会话已死仍无画面**：抛错。
/// - **纯音频**：确认无视轨后仍要进度前进（与点播相同）。
/// - **播放中进度卡死**：点播在「出画/纯音频」后若 [isPlaying] 且进度长期不涨 → 抛错切播放器。
///   直播（[isLiveContent] / 时长一直为 0）跳过进度检查。
Future<void> kotvGuardSilentVideo({
  required bool Function() hasVideoSize,
  required bool Function() sessionAlive,
  required bool Function() isBuffering,
  bool Function()? isAudioOnly,
  bool Function()? hasVideoSource,
  Future<void> Function()? onFixVideoSource,
  /// 当前播放进度；用于「在播但进度不动」检测。
  Duration Function()? position,
  /// 片长；点播通常 >0。一直为 0 且已出画时按直播放行。
  Duration Function()? duration,
  /// 是否明确为直播；为 true 时不做进度卡死判定。
  bool Function()? isLiveContent,
  /// 是否处于播放中（比 sessionAlive 更严；缺省用 sessionAlive）。
  bool Function()? isPlaying,
  Duration sourceFixTimeout = const Duration(seconds: 8),
  Duration blackScreenTimeout = const Duration(seconds: 8),
  Duration sessionDeadTimeout = const Duration(seconds: 2),
  Duration sizeSettleTimeout = const Duration(milliseconds: 400),
  /// 出画/纯音频后，播放中进度需在此时间内前进，否则视为空转。
  Duration progressStallTimeout = const Duration(seconds: 8),
  /// 进度至少前进这么多才算「动了」。
  Duration progressMinDelta = const Duration(milliseconds: 400),
  /// 一直缓冲却始终无画面/未真正起播：超时抛错，交给 [KotvPlaybackFailover]。
  Duration bufferingNoVideoTimeout = const Duration(seconds: 18),
  Duration tick = const Duration(milliseconds: 200),
}) async {
  DateTime? blackSince;
  DateTime? sourceWaitSince;
  DateTime? deadSince;
  DateTime? sizeSince;
  DateTime? bufferingNoVideoSince;
  var sourceFixDone = false;
  var blackFixDone = false;

  Future<void> ensureProgressOrThrow() async {
    if (isLiveContent?.call() == true) return;
    final playingOf = isPlaying ?? sessionAlive;
    final posOf = position;
    final durOf = duration;
    if (posOf == null) return;

    final baseline = posOf();
    DateTime? stallSince;
    final watchStart = DateTime.now();

    while (true) {
      final now = DateTime.now();
      if (isLiveContent?.call() == true) return;
      if (isAudioOnly?.call() == true) {
        // 纯音频也要进度；下面统一看 position。
      } else if (!hasVideoSize() && isAudioOnly?.call() != true) {
        // 出画又丢了：回到主循环处理。
        return;
      }

      final pos = posOf();
      // 起播已越过门槛，或监视窗口内相对前进，都算进度正常。
      if (pos >= progressMinDelta) return;
      if (pos - baseline >= progressMinDelta) return;

      final dur = durOf?.call() ?? Duration.zero;
      final playing = playingOf();
      final buffering = isBuffering();

      // 时长一直未知且已出画：更像直播，超时后放行。
      if (dur <= Duration.zero &&
          (hasVideoSize() || isAudioOnly?.call() == true) &&
          now.difference(watchStart) >= progressStallTimeout) {
        return;
      }

      // 缓冲中（含 playing+buffering 的补缓存）不计进度停滞，避免误切播放器。
      if (buffering) {
        stallSince = null;
        await Future<void>.delayed(tick);
        continue;
      }

      if (!sessionAlive()) {
        throw const KotvSilentVideoException('起播会话中断无画面');
      }

      if (playing) {
        stallSince ??= now;
        if (now.difference(stallSince) >= progressStallTimeout) {
          throw const KotvSilentVideoException('播放中进度停滞');
        }
      } else {
        stallSince = null;
        // 已出画但尚未进入 playing：继续短等，避免永久挂死。
        if (now.difference(watchStart) >= progressStallTimeout * 2) {
          throw const KotvSilentVideoException('播放中进度停滞');
        }
      }
      await Future<void>.delayed(tick);
    }
  }

  while (true) {
    final now = DateTime.now();

    final audioOnly = isAudioOnly?.call() == true;
    if (audioOnly) {
      await ensureProgressOrThrow();
      if (isAudioOnly?.call() == true || hasVideoSize()) return;
      // 进度检查中途失去 audio-only 且仍无画面：继续主循环。
    }

    if (hasVideoSize()) {
      bufferingNoVideoSince = null;
      sizeSince ??= now;
      if (now.difference(sizeSince) >= sizeSettleTimeout) {
        await ensureProgressOrThrow();
        if (hasVideoSize() || isAudioOnly?.call() == true) return;
        sizeSince = null;
        continue;
      }
      await Future<void>.delayed(tick);
      continue;
    }
    sizeSince = null;

    // 缓冲很久仍无画面：MPV/硬解卡死常见；勿因 isBuffering&&!alive 永久空转。
    if (isBuffering()) {
      bufferingNoVideoSince ??= now;
      if (now.difference(bufferingNoVideoSince!) >= bufferingNoVideoTimeout) {
        throw const KotvSilentVideoException('缓冲过久仍无画面');
      }
    } else {
      bufferingNoVideoSince = null;
    }

    final alive = sessionAlive();

    if (isBuffering() && !alive) {
      blackSince = null;
      sourceWaitSince = null;
      deadSince = null;
      await Future<void>.delayed(tick);
      continue;
    }

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
        sourceWaitSince = DateTime.now();
        await Future<void>.delayed(tick);
        continue;
      }
      sourceWaitSince ??= now;
      if (now.difference(sourceWaitSince) < sourceFixTimeout) {
        await Future<void>.delayed(tick);
        continue;
      }
      if (isAudioOnly?.call() == true) {
        await ensureProgressOrThrow();
        return;
      }
      throw const KotvSilentVideoException('无可用视频源');
    }

    if (!sourceFixDone) {
      sourceFixDone = true;
      await onFixVideoSource?.call();
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
      blackSince = DateTime.now();
      await Future<void>.delayed(tick);
      continue;
    }

    if (isAudioOnly?.call() == true) {
      await ensureProgressOrThrow();
      return;
    }
    throw const KotvSilentVideoException();
  }
}
