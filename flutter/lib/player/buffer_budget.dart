import 'dart:math' show max;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'kotv_platform.dart';

/// 各播放器共用的「前向缓冲」内存预算（字节）。
///
/// 策略（Exo / MPV / 外部 VLC prefetch 对齐）：
/// 1. **按内存上限**囤前向缓冲，不用「剩余播放秒数」当预读目标；
/// 2. 播出去的数据应释放，allocated 降到预算以下后**继续补满**到上限；
/// 3. 不设 mpv `cache-secs` / `demuxer-readahead-secs` 等**固定秒数**预读目标。
///
/// Web / HTML5：由浏览器自己管缓冲，不走本预算。
///
/// 预算按**当前可用内存**为主、总内存为辅估算，再钳到平台上下限。
class KotvBufferBudget {
  KotvBufferBudget._();

  static const _android = MethodChannel('kotv_android');
  static const _host = MethodChannel('kotv_host');
  static int? _cached;

  /// mpv 点播缓冲：仅字节预算；`demuxer-max-bytes` 是上限不是起播门槛。
  static Map<String, String> mpvCacheProps(int budgetBytes) {
    final forward = mpvMiB(budgetBytes);
    final back = mpvMiB(max(16 * 1024 * 1024, budgetBytes ~/ 8));
    return {
      'cache': 'yes',
      'cache-on-disk': 'no',
      'demuxer-max-bytes': forward,
      'demuxer-max-back-bytes': back,
      'cache-pause-initial': 'no',
      'framedrop': 'vo',
    };
  }

  /// 直播：对齐 TV——不写 `demuxer-max-bytes` / `cache-secs`（mpv 默认即可）。
  ///
  /// 点播才用 [mpvCacheProps]；直播页勿再套小 demuxer 或 cache-pause 门槛。
  static Map<String, String> mpvLiveCacheProps() => const {};

  /// 同步读取（未 [warm] 时用平台启发式）。
  static int bytes() => _cached ?? _fallback();

  /// 读取/刷新预算。各平台读真实 total/avail；[force] 时按当前可用内存重算。
  static Future<int> warm({bool force = false}) async {
    if (!force && _cached != null) return _cached!;
    try {
      Map<dynamic, dynamic>? raw;
      if (kotvIsAndroid()) {
        final v = await _android.invokeMethod<dynamic>('getMemoryInfo');
        if (v is Map) raw = v;
      } else if (kotvIsDesktop()) {
        final v = await _host.invokeMethod<dynamic>('getMemoryInfo');
        if (v is Map) raw = v;
      }
      if (raw != null) {
        final total = (raw['totalBytes'] as num?)?.toInt() ?? 0;
        final avail = (raw['availBytes'] as num?)?.toInt() ?? 0;
        if (total > 0) {
          _cached = fromDevice(
            totalBytes: total,
            availBytes: avail,
            desktop: kotvIsDesktop(),
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

  /// mdk [setBufferRange] 只有毫秒 API；用内存预算 ÷ 参考码率换算，不用固定秒数。
  static int fvpMaxBufferMs(int budgetBytes, {int refBitsPerSec = 4 * 1000 * 1000}) {
    final bps = refBitsPerSec <= 0 ? 4 * 1000 * 1000 : refBitsPerSec;
    final bytesPerSec = bps / 8.0;
    final ms = (budgetBytes / bytesPerSec * 1000.0).round();
    if (ms < 1000) return 1000;
    if (ms > 2 * 3600 * 1000) return 2 * 3600 * 1000;
    return ms;
  }

  @visibleForTesting
  static void debugReset() => _cached = null;
}
