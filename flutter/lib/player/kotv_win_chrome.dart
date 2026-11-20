import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'danmaku_layer.dart';
import 'kotv_platform.dart';

/// Win7 原生播控/弹幕/缓冲套壳通道。Win8+ DComp 路径不使用。
class KotvWinChrome {
  KotvWinChrome._();

  static const _ch = MethodChannel('kotv_win_chrome');
  static void Function(Map<String, dynamic> event)? onEvent;
  static bool _handlerBound = false;
  static int _lastDanmakuSig = 0;

  static bool get isNeeded => kotvUsesWindowsNativeChrome();

  static void _ensureHandler() {
    if (_handlerBound || kIsWeb) return;
    _handlerBound = true;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'event') {
        final args = call.arguments;
        if (args is Map) {
          onEvent?.call(Map<String, dynamic>.from(args));
        }
      }
      return null;
    });
  }

  static Future<void> setEnabled(bool enabled) async {
    if (!isNeeded) return;
    _ensureHandler();
    try {
      await _ch.invokeMethod('setEnabled', {'enabled': enabled});
      if (!enabled) _lastDanmakuSig = 0;
    } catch (_) {}
  }

  static Future<void> update(Map<String, dynamic> fields) async {
    if (!isNeeded) return;
    _ensureHandler();
    try {
      await _ch.invokeMethod('update', fields);
    } catch (_) {}
  }

  static Future<void> layout() async {
    if (!isNeeded) return;
    try {
      await _ch.invokeMethod('layout');
    } catch (_) {}
  }

  /// 下发弹幕列表与样式；[items] 签名未变则只更新开关/样式。
  static Future<void> setDanmaku({
    required bool enabled,
    required List<DanmakuItem> items,
    double fontSize = 18,
    double opacity = 0.85,
    int durationMs = 8000,
    int fixedDurationMs = 5000,
    int rows = 6,
    bool showScroll = true,
    bool showTop = true,
    bool showBottom = true,
    bool showReverse = true,
  }) async {
    if (!isNeeded) return;
    _ensureHandler();
    final sig = Object.hash(
      items.length,
      items.isEmpty ? 0 : items.first.time,
      items.isEmpty ? 0 : items.last.time,
      items.isEmpty ? 0 : items.first.content.hashCode,
      enabled,
      fontSize,
      rows,
    );
    final itemsChanged = sig != _lastDanmakuSig;
    _lastDanmakuSig = sig;
    try {
      final map = <String, dynamic>{
        'enabled': enabled,
        'fontSize': fontSize,
        'opacity': opacity,
        'durationMs': durationMs,
        'fixedDurationMs': fixedDurationMs,
        'rows': rows,
        'showScroll': showScroll,
        'showTop': showTop,
        'showBottom': showBottom,
        'showReverse': showReverse,
      };
      if (itemsChanged) {
        // 限制条数，避免一次塞爆通道。
        const maxItems = 4000;
        final src = items.length > maxItems
            ? items.sublist(items.length - maxItems)
            : items;
        map['items'] = [
          for (final it in src)
            {
              't': it.time,
              'c': it.content,
              'm': it.mode,
              'color': it.color,
              'size': it.size,
            },
        ];
      }
      await _ch.invokeMethod('setDanmaku', map);
    } catch (_) {}
  }
}
