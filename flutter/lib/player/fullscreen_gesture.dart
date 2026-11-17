import 'dart:ui' show Offset, Size;

import 'gesture_brightness_volume.dart';

export 'gesture_brightness_volume.dart';

/// 全屏触屏手势常量与侧边亮度/音量会话（点播全屏共用）。
abstract final class KotvFsGesture {
  /// 靠边忽略（与悬停开选集边缘一致）。
  static const edgeIgnore = 24.0;

  /// 横向位移 1px → 预览毫秒。
  static const seekMsPerPx = 50;

  static bool isLeftQuarter(double x, double width) => x <= width / 4;

  static bool isRightQuarter(double x, double width) => x >= width * 3 / 4;

  static bool isEdge(Offset p, Size size) =>
      p.dx < edgeIgnore ||
      p.dy < edgeIgnore ||
      p.dx > size.width - edgeIgnore ||
      p.dy > size.height - edgeIgnore;
}

/// 侧边亮度 / 音量跟手会话。
class KotvSideGestureSession {
  KotvSideGestureSession._(this.kind, this.base, {required this.useSystemVolume})
      : percent = base;

  factory KotvSideGestureSession.bright(double base) =>
      KotvSideGestureSession._('bright', base.clamp(0, 100), useSystemVolume: false);

  factory KotvSideGestureSession.volume(double base, {required bool system}) =>
      KotvSideGestureSession._('volume', base.clamp(0, 100), useSystemVolume: system);

  final String kind;
  final double base;
  final bool useSystemVolume;
  double percent;

  static Future<KotvSideGestureSession> beginBright() async {
    final b = await KotvGestureBrightVol.getBrightness();
    return KotvSideGestureSession.bright(b ?? 50);
  }

  static Future<KotvSideGestureSession> beginVolume({required double playerVolume}) async {
    final sys = await KotvGestureBrightVol.getSystemVolume();
    if (sys != null) return KotvSideGestureSession.volume(sys, system: true);
    return KotvSideGestureSession.volume(playerVolume, system: false);
  }

  /// [upPositive]：上滑增大（屏幕 dy 向下为正时传入 -dy）。
  double apply(double upPositive, double height) {
    percent = (base + upPositive * 2.0 / height * 100).clamp(0.0, 100.0);
    return percent;
  }

  Future<void> applyHardware() async {
    if (kind == 'bright') {
      await KotvGestureBrightVol.setBrightness(percent);
      return;
    }
    if (useSystemVolume) {
      await KotvGestureBrightVol.setSystemVolume(percent);
    }
  }
}
