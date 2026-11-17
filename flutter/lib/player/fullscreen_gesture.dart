import 'dart:ui' show Offset, Size;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/services.dart' show HardwareKeyboard, LogicalKeyboardKey;

import 'gesture_brightness_volume.dart';
import 'kotv_platform.dart';

export 'gesture_brightness_volume.dart';

/// 点播全屏手势模式（拖分区 + 捏合；滚轮不占此态）。
enum KotvFsMode { none, seek, bright, volume, ep, pinch }

/// 滚轮 / 触控板双指：音量或 seek。
enum KotvFsScrollKind { none, volume, seek }

/// 全屏手势常量、分区判定与侧边亮/音会话（点播全屏唯一策略层）。
abstract final class KotvFsGesture {
  static const edgeIgnore = 24.0;
  static const seekMsPerPx = 50;
  static const wheelVolumeStep = 4.0;
  static const wheelSeekStep = Duration(seconds: 5);
  static const wheelHudSettle = Duration(milliseconds: 700);
  static const scrollAxisBias = 1.15;

  static bool get supportsBrightness =>
      !kIsWeb && (kotvIsAndroid() || kotvIsIOS());

  static bool isTouchLike(PointerDeviceKind kind) =>
      kind == PointerDeviceKind.touch ||
      kind == PointerDeviceKind.stylus ||
      kind == PointerDeviceKind.invertedStylus;

  static bool get shiftPressed =>
      HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.shiftLeft) ||
      HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.shiftRight);

  static bool isLeftQuarter(double x, double width) => x <= width / 4;

  static bool isRightQuarter(double x, double width) => x >= width * 3 / 4;

  static bool isEdge(Offset p, Size size) =>
      p.dx < edgeIgnore ||
      p.dy < edgeIgnore ||
      p.dx > size.width - edgeIgnore ||
      p.dy > size.height - edgeIgnore;

  /// [television]：仅竖滑切集。否则 seek / 亮（有通道）/ 音 / 中区切集。
  static KotvFsMode classifyDrag({
    required Offset total,
    required double downX,
    required double width,
    required bool canEp,
    required bool television,
  }) {
    if (television) {
      if (!canEp || total.dy.abs() <= total.dx.abs()) return KotvFsMode.none;
      return KotvFsMode.ep;
    }
    if (total.dx.abs() >= total.dy.abs()) return KotvFsMode.seek;
    if (isLeftQuarter(downX, width)) {
      if (supportsBrightness) return KotvFsMode.bright;
      return canEp ? KotvFsMode.ep : KotvFsMode.none;
    }
    if (isRightQuarter(downX, width)) return KotvFsMode.volume;
    return canEp ? KotvFsMode.ep : KotvFsMode.none;
  }

  static KotvFsScrollKind classifyScroll({
    required double dx,
    required double dy,
    required bool shift,
  }) {
    if (dx == 0 && dy == 0) return KotvFsScrollKind.none;
    if (shift && dy != 0) return KotvFsScrollKind.seek;
    if (dx.abs() > dy.abs() * scrollAxisBias) return KotvFsScrollKind.seek;
    if (dy != 0) return KotvFsScrollKind.volume;
    if (dx != 0) return KotvFsScrollKind.seek;
    return KotvFsScrollKind.none;
  }

  static double volumeDeltaFromScrollDy(double scrollDy) {
    if (scrollDy == 0) return 0;
    final steps = (scrollDy.abs() / 40.0).clamp(1.0, 4.0);
    return -scrollDy.sign * wheelVolumeStep * steps;
  }

  static Duration seekDeltaFromScroll({
    required double dx,
    required double dy,
    required bool shift,
  }) {
    final along = shift || dx.abs() <= dy.abs() ? -dy : -dx;
    if (along == 0) return Duration.zero;
    final steps = (along.abs() / 40.0).clamp(1.0, 4.0).round();
    final sign = along > 0 ? 1 : -1;
    return wheelSeekStep * (sign * steps);
  }
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

  static Future<KotvSideGestureSession?> beginBright() async {
    if (!KotvFsGesture.supportsBrightness) return null;
    final b = await KotvGestureBrightVol.getBrightness();
    if (b == null) return null;
    return KotvSideGestureSession.bright(b);
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

  void applyPercentDelta(double delta) {
    percent = (percent + delta).clamp(0.0, 100.0);
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

  /// 写硬件；非系统音量时回调播放器音量。
  Future<void> flush({Future<void> Function(double percent)? setPlayerVolume}) async {
    await applyHardware();
    if (kind == 'volume' && !useSystemVolume && setPlayerVolume != null) {
      await setPlayerVolume(percent);
    }
  }
}
