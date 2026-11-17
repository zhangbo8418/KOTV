import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

import 'kotv_platform.dart';

/// 全屏手势：窗口亮度 / 系统或播放器音量（0–100）。
class KotvGestureBrightVol {
  KotvGestureBrightVol._();

  static const _android = MethodChannel('kotv_android');
  static const _host = MethodChannel('kotv_host');

  /// 当前窗口亮度 0–100；不可用返回 null。
  static Future<double?> getBrightness() async {
    if (kIsWeb) return null;
    try {
      if (kotvIsAndroid()) {
        final v = await _android.invokeMethod<num>('getBrightness');
        return v?.toDouble();
      }
      if (kotvIsIOS()) {
        final v = await _host.invokeMethod<num>('getBrightness');
        return v?.toDouble();
      }
    } catch (_) {}
    return null;
  }

  static Future<void> setBrightness(double percent) async {
    if (kIsWeb) return;
    final p = percent.clamp(0.0, 100.0);
    try {
      if (kotvIsAndroid()) {
        await _android.invokeMethod<void>('setBrightness', p);
        return;
      }
      if (kotvIsIOS()) {
        await _host.invokeMethod<void>('setBrightness', p);
      }
    } catch (_) {}
  }

  /// 系统媒体音量 0–100；桌面/失败返回 null（改用播放器音量）。
  static Future<double?> getSystemVolume() async {
    if (kIsWeb || !kotvIsAndroid()) return null;
    try {
      final v = await _android.invokeMethod<num>('getSystemVolume');
      return v?.toDouble();
    } catch (_) {
      return null;
    }
  }

  static Future<void> setSystemVolume(double percent) async {
    if (kIsWeb || !kotvIsAndroid()) return;
    try {
      await _android.invokeMethod<void>('setSystemVolume', percent.clamp(0.0, 100.0));
    } catch (_) {}
  }
}
