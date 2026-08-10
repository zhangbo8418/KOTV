import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'kotv_platform.dart';

/// 各播放器共用的「前向缓冲」内存预算（字节）。
///
/// 策略（Exo / MPV / ijk / 桌面 VLC prefetch 对齐）：
/// 1. **按内存上限**囤前向缓冲，不用「剩余播放秒数」当预读目标；
/// 2. 播出去的数据应释放，allocated 降到预算以下后**继续补满**到上限；
/// 3. 短时长参数只用于「能否起播 / 卡顿后重开」，不控制囤多少
///   （VLC 的 network-caching 属第 3 类；字节囤靠 prefetch-buffer-size）。
///
/// Web / HTML5：由浏览器自己管缓冲，不走本预算。
///
/// 预算按**当前可用内存**为主、总内存为辅估算，再钳到平台上下限。
class KotvBufferBudget {
  KotvBufferBudget._();

  static const _android = MethodChannel('kotv_android');
  static int? _cached;

  /// 同步读取（未 [warm] 时用平台启发式）。
  static int bytes() => _cached ?? _fallback();

  /// 读取/刷新预算。Android 读真实 total/avail；[force] 时按当前可用内存重算。
  static Future<int> warm({bool force = false}) async {
    if (!force && _cached != null) return _cached!;
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

  /// 可用内存优先：约 15% avail，且不超过总内存 5%；再钳到平台上下限。
  static int fromDevice({
    required int totalBytes,
    required int availBytes,
    required bool desktop,
  }) {
    final total = totalBytes > 0
        ? totalBytes
        : (desktop ? 8 * 1024 * 1024 * 1024 : 3 * 1024 * 1024 * 1024);
    final byTotal = (total * 0.05).round();
    int budget;
    if (availBytes > 0) {
      final byAvail = (availBytes * 0.15).round();
      // 可用少时跟 avail；可用充裕时也不超过总内存比例
      budget = byAvail < byTotal ? byAvail : byTotal;
    } else {
      budget = byTotal;
    }
    final minB = desktop ? 48 * 1024 * 1024 : 24 * 1024 * 1024;
    // 上限仍钳制，防止极端机器把 demuxer 开到数 GB
    final maxB = desktop ? 384 * 1024 * 1024 : 96 * 1024 * 1024;
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
