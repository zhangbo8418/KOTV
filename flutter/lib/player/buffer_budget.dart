import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'kotv_platform.dart';

/// 各播放器共用的「前向缓冲」内存预算（字节）。
///
/// 按设备物理内存比例估算，并受可用内存与上下限钳制；
/// **不以固定时长为目标**，避免 4K/8K 高码率按时间窗撑爆堆。
class KotvBufferBudget {
  KotvBufferBudget._();

  static const _android = MethodChannel('kotv_android');
  static int? _cached;

  /// 同步读取（未 [warm] 时用平台启发式）。
  static int bytes() => _cached ?? _fallback();

  /// 尽量在启动或开播前调用，Android 会读真实 total/avail。
  static Future<int> warm() async {
    if (_cached != null) return _cached!;
    try {
      if (kotvIsAndroid()) {
        final raw = await _android.invokeMethod<dynamic>('getMemoryInfo');
        if (raw is Map) {
          final total = (raw['totalBytes'] as num?)?.toInt() ?? 0;
          final avail = (raw['availBytes'] as num?)?.toInt() ?? 0;
          _cached = fromDevice(
            totalBytes: total,
            availBytes: avail,
            desktop: false,
          );
          return _cached!;
        }
      }
    } catch (_) {}
    _cached = _fallback();
    return _cached!;
  }

  /// 统一公式：约 5% 总内存，且不超过可用内存的 20%；再钳到平台上下限。
  static int fromDevice({
    required int totalBytes,
    required int availBytes,
    required bool desktop,
  }) {
    final total = totalBytes > 0
        ? totalBytes
        : (desktop ? 8 * 1024 * 1024 * 1024 : 3 * 1024 * 1024 * 1024);
    var budget = (total * 0.05).round();
    if (availBytes > 0) {
      final byAvail = (availBytes * 0.20).round();
      if (byAvail > 0 && byAvail < budget) budget = byAvail;
    }
    final minB = desktop ? 48 * 1024 * 1024 : 24 * 1024 * 1024;
    // 手机上限压到 64MiB：解码器 + 纹理 + demuxer 再叠 128MiB 很容易触发
    // GC 抖动甚至 OOM，全屏播放会掉帧。
    final maxB = desktop ? 384 * 1024 * 1024 : 64 * 1024 * 1024;
    if (budget < minB) budget = minB;
    if (budget > maxB) budget = maxB;
    return budget;
  }

  static int _fallback() => fromDevice(
        totalBytes: kotvIsDesktop() ? 8 * 1024 * 1024 * 1024 : 4 * 1024 * 1024 * 1024,
        availBytes: 0,
        desktop: kotvIsDesktop(),
      );

  /// mpv `demuxer-max-bytes` 风格：`96MiB`。
  static String mpvMiB(int n) {
    final mib = (n / (1024 * 1024)).round().clamp(16, 4096);
    return '${mib}MiB';
  }

  @visibleForTesting
  static void debugReset() => _cached = null;
}
