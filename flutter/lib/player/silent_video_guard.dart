import 'kotv_playback.dart';

/// 各播放器共用的开播画面守卫（阶梯判定，抛错前尽量自愈）。
///
/// 1. **缓冲中**：最多等 [bufferingTimeout]（默认 60s）
/// 2. **纯音频**（[isAudioOnly]）：不要求画面，直接成功
/// 3. **视源异常**（有视轨但未选中 / 元数据异常）：[onFixVideoSource] + [sourceFixTimeout]
/// 4. **有视源但仍无尺寸**（黑屏）：[blackScreenTimeout]（默认 5s）后再修一次，仍失败则抛
///    [KotvSilentVideoException]
///
/// **刻意不做**：「已有尺寸但进度长期不动」——静态封面音乐等合法内容会被误杀；
/// 有尺寸即视为出画成功，是否继续播由用户判断。
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
    if (isAudioOnly?.call() == true) return;

    final now = DateTime.now();
    if (now.difference(started) >= bufferingTimeout) {
      // 超时前再认一次纯音频，避免慢 demux 的音乐被误杀。
      if (isAudioOnly?.call() == true) return;
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
