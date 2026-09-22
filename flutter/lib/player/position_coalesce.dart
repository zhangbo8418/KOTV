/// 原生播放器（Exo / MPV）`position` 事件的合并判定。
///
/// 事件按帧节奏到达；只有状态位变化、进度差 ≥200ms、缓冲差 ≥500ms 或时长变化时才通知 UI，
/// 其余仅更新内部字段与 Stream。两处解析共用同一阈值。
class KotvPositionSample {
  const KotvPositionSample({
    required this.position,
    required this.duration,
    required this.buffered,
    required this.playing,
    required this.buffering,
    required this.speedBps,
  });

  final Duration position;
  final Duration duration;
  final Duration buffered;
  final bool playing;
  final bool buffering;
  final int speedBps;

  /// 从事件 Map 构造；缺失的 bufferedMs / speedBps 用上一份样本补齐。
  factory KotvPositionSample.fromEvent(Map<String, dynamic> m, KotvPositionSample prev) {
    final speed = (m['speedBps'] as num?)?.toInt() ?? prev.speedBps;
    return KotvPositionSample(
      position: Duration(milliseconds: (m['positionMs'] as num?)?.toInt() ?? 0),
      duration: Duration(milliseconds: (m['durationMs'] as num?)?.toInt() ?? 0),
      buffered: Duration(milliseconds: (m['bufferedMs'] as num?)?.toInt() ?? prev.buffered.inMilliseconds),
      playing: m['playing'] == true,
      buffering: m['buffering'] == true,
      speedBps: speed < 0 ? 0 : speed,
    );
  }

  /// 是否需要 notifyListeners。
  bool shouldNotify(KotvPositionSample prev) {
    return playing != prev.playing ||
        buffering != prev.buffering ||
        speedBps != prev.speedBps ||
        (position - prev.position).inMilliseconds.abs() >= 200 ||
        (buffered - prev.buffered).inMilliseconds.abs() >= 500 ||
        duration != prev.duration;
  }
}
