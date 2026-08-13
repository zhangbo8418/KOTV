import 'dart:convert';
import 'dart:math' show max;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'kotv_platform.dart';

/// 缓冲浮层统一测速（[Traffic]：与播放器解耦）。
///
/// 累计字节来源（各自建基线，取最大正速度）：
/// 1. Go 引擎 `/api/v1/net`（代理拉流真下行，全平台）
/// 2. Android `TrafficStats` UID（含同 UID 引擎子进程）
/// 3. 桌面网卡 `ifi_ibytes`（MPV/VLC 直连时引擎计数为 0）
/// 4. 调用方传入的播放器 `networkSpeedBps`（无增长时兜底）
class KotvTraffic {
  KotvTraffic._();

  static const _android = MethodChannel('kotv_android');
  static const _host = MethodChannel('kotv_host');

  /// 由 [EngineLauncher] / 设置页同步。
  static String engineBaseUrl = 'http://127.0.0.1:9978';

  static final Map<String, ({int bytes, int atMs})> _base = {};
  static int _speedBps = 0;

  static void reset() {
    _base.clear();
    _speedBps = 0;
  }

  /// 采样一次，返回 bytes/s。各累计源首拍建基线时为 0（同 TV）。
  static Future<int> sampleBps({int playerFallbackBps = 0}) async {
    final speeds = <int>[];

    final engine = await _engineRxBytes();
    if (engine != null) {
      final s = _diffSource('engine', engine);
      if (s != null && s > 0) speeds.add(s);
    }

    final uid = await _uidRxBytes();
    if (uid != null) {
      final s = _diffSource('uid', uid);
      if (s != null && s > 0) speeds.add(s);
    }

    final iface = await _ifaceRxBytes();
    if (iface != null) {
      final s = _diffSource('iface', iface);
      if (s != null && s > 0) speeds.add(s);
    }

    if (speeds.isNotEmpty) {
      _speedBps = speeds.reduce(max);
      return _speedBps;
    }

    final fb = playerFallbackBps < 0 ? 0 : playerFallbackBps;
    if (fb > 0) {
      _speedBps = fb;
      return _speedBps;
    }

    _speedBps = 0;
    return 0;
  }

  /// 返回本源瞬时 B/s；首拍或间隔过短返回 null（不覆盖总结果）。
  static int? _diffSource(String source, int bytes) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final prev = _base[source];
    if (prev == null) {
      _base[source] = (bytes: bytes, atMs: now);
      return 0;
    }
    final dt = now - prev.atMs;
    if (dt < 200) return null;
    final delta = bytes - prev.bytes;
    _base[source] = (bytes: bytes, atMs: now);
    return delta > 0 ? ((delta * 1000) / dt).round().clamp(0, 1 << 30) : 0;
  }

  static Future<int?> _engineRxBytes() async {
    final base = engineBaseUrl.trim();
    if (base.isEmpty) return null;
    try {
      final uri = Uri.parse('$base/api/v1/net');
      final res = await http.get(uri).timeout(const Duration(milliseconds: 800));
      if (res.statusCode != 200) return null;
      final map = jsonDecode(utf8.decode(res.bodyBytes));
      if (map is! Map) return null;
      final v = map['rxBytes'];
      if (v is num) return v.toInt();
      return int.tryParse('$v');
    } catch (_) {
      return null;
    }
  }

  static Future<int?> _uidRxBytes() async {
    if (!kotvIsAndroid()) return null;
    try {
      final v = await _android.invokeMethod<dynamic>('getUidRxBytes');
      final n = (v as num?)?.toInt() ?? -1;
      return n < 0 ? null : n;
    } catch (_) {
      return null;
    }
  }

  static Future<int?> _ifaceRxBytes() async {
    if (!kotvIsDesktop()) return null;
    try {
      final v = await _host.invokeMethod<dynamic>('getInterfaceRxBytes');
      final n = (v as num?)?.toInt() ?? -1;
      return n < 0 ? null : n;
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  static void debugReset() => reset();
}
