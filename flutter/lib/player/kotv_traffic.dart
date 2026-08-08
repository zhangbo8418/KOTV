import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'kotv_platform.dart';

/// 进程 UID 下行测速（对齐 TV [Traffic]：`TrafficStats.getUidRxBytes`）。
///
/// 与播放器内部 tcp/cache 无关：引擎代理拉流、HLS 分片等凡进本 UID 的流量都会计入，
/// 所以起播缓冲阶段就能出真实网速，而不会卡在各引擎「建基线强制 0」。
class KotvTraffic {
  KotvTraffic._();

  static const _android = MethodChannel('kotv_android');

  static int _lastRxBytes = 0;
  static int _lastAtMs = 0;
  static int _speedBps = 0;

  /// 当前平台是否支持 UID 流量差分（目前仅 Android，与 TV 一致）。
  static bool get supported => kotvIsAndroid();

  static void reset() {
    _lastRxBytes = 0;
    _lastAtMs = 0;
    _speedBps = 0;
  }

  /// 采样一次，返回 bytes/s。不支持时返回 -1；首帧建基线时返回 0（同 TV）。
  static Future<int> sampleBps() async {
    if (!supported) return -1;
    int rx;
    try {
      final v = await _android.invokeMethod<dynamic>('getUidRxBytes');
      rx = (v as num?)?.toInt() ?? -1;
    } catch (_) {
      return -1;
    }
    if (rx < 0) return -1;

    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastAtMs <= 0) {
      // 对齐 TV：reset 后第一次只建基线；分母用 epoch 时结果≈0，不会刷假高速。
      _lastRxBytes = rx;
      _lastAtMs = now;
      _speedBps = 0;
      return 0;
    }
    final dt = now - _lastAtMs;
    if (dt < 200) return _speedBps;
    final delta = rx - _lastRxBytes;
    _speedBps = delta > 0 ? ((delta * 1000) / dt).round().clamp(0, 1 << 30) : 0;
    _lastRxBytes = rx;
    _lastAtMs = now;
    return _speedBps;
  }

  @visibleForTesting
  static void debugReset() => reset();
}
