import 'kotv_playback.dart';

/// 各播放器共用的**起播**画面守卫（抛错前尽量自愈；不负责播中卡顿）。
///
/// ## 原则
/// - **未在播的缓冲**：只等，**不超时、不切播放器**（慢源/磁力）。
/// - **已在播（[sessionAlive]）却无尺寸**：按黑屏处理——即使引擎仍报 buffering
///   （很多播放器首帧前会一直标缓冲）。
/// - **有尺寸即成功**：不做「进度卡死」误判。
/// - **纯音频**：仅在引擎确认无视轨时放行，禁止用「在播+无尺寸」瞎猜。
///
/// ## 阶梯
/// 1. 缓冲且会话未活 → 一直等
/// 2. 纯音频（[isAudioOnly]）→ 成功
/// 3. 视源异常 → [onFixVideoSource] + [sourceFixTimeout]
/// 4. 已在播/有源但黑屏 → [blackScreenTimeout]（默认 8s）后再修一次，仍失败则抛
///    [KotvSilentVideoException]
///
/// 解码翻转 / 换播放器由上层 failover 处理。
Future<void> kotvGuardSilentVideo({
  required bool Function() hasVideoSize,
  required bool Function() sessionAlive,
  required bool Function() isBuffering,
  /// 已确认片源无视频轨（音乐等）；为 true 时守卫成功返回。
  bool Function()? isAudioOnly,
  /// 是否已挂上可用视频源/轨；`null` 表示引擎无法判断（视为有源）。
  bool Function()? hasVideoSource,
  Future<void> Function()? onFixVideoSource,
  Duration sourceFixTimeout = const Duration(seconds: 8),
  Duration blackScreenTimeout = const Duration(seconds: 8),
  /// 会话已死且仍无画面时，短暂观察后结束守卫（不抛 SilentVideo，避免误切播放器）。
  Duration sessionDeadTimeout = const Duration(seconds: 2),
  Duration tick = const Duration(milliseconds: 200),
}) async {
  DateTime? blackSince;
  DateTime? sourceWaitSince;
  DateTime? deadSince;
  var sourceFixDone = false;
  var blackFixDone = false;

  while (true) {
    if (hasVideoSize()) return;
    if (isAudioOnly?.call() == true) return;

    final now = DateTime.now();
    final alive = sessionAlive();

    // —— 仅「还在拉、尚未形成在播」才无限等；已在播的假 buffering 走黑屏 ——
    if (isBuffering() && !alive) {
      blackSince = null;
      sourceWaitSince = null;
      deadSince = null;
      await Future<void>.delayed(tick);
      continue;
    }

    // —— 会话已死：交给引擎错误文案，不走黑屏 failover ——
    if (!alive) {
      blackSince = null;
      sourceWaitSince = null;
      deadSince ??= now;
      if (now.difference(deadSince) >= sessionDeadTimeout) {
        return;
      }
      await Future<void>.delayed(tick);
      continue;
    }
    deadSince = null;

    // —— 视源异常（期望有视频但未挂上正确轨）——
    final sourceOk = hasVideoSource?.call() ?? true;
    if (!sourceOk) {
      blackSince = null;
      if (!sourceFixDone) {
        sourceFixDone = true;
        await onFixVideoSource?.call();
        if (hasVideoSize()) return;
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

    // —— 有源提示但仍无画面尺寸：黑屏窗口 ——
    if (!sourceFixDone) {
      sourceFixDone = true;
      await onFixVideoSource?.call();
      if (hasVideoSize()) return;
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
      if (hasVideoSize()) return;
      if (isAudioOnly?.call() == true) return;
      blackSince = DateTime.now();
      await Future<void>.delayed(tick);
      continue;
    }

    if (isAudioOnly?.call() == true) return;
    throw const KotvSilentVideoException();
  }
}
