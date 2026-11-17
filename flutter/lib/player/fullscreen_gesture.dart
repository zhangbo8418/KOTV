import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/services.dart' show HardwareKeyboard, LogicalKeyboardKey;
import 'package:vector_math/vector_math_64.dart' show Matrix4;

import 'gesture_brightness_volume.dart';
import 'kotv_platform.dart';

export 'gesture_brightness_volume.dart';

/// 全屏手势模式（点播切集 / 直播换台 / 捏合；滚轮不占此态）。
enum KotvFsMode { none, seek, bright, volume, ep, channel, pinch }

/// 滚轮 / 触控板双指：音量或 seek。
enum KotvFsScrollKind { none, volume, seek }

/// 全屏手势常量、分区判定与侧边亮/音会话（点播 / 直播共用策略层）。
abstract final class KotvFsGesture {
  static const edgeIgnore = 24.0;
  static const seekMsPerPx = 50;
  static const wheelVolumeStep = 4.0;
  static const wheelSeekStep = Duration(seconds: 5);
  static const wheelHudSettle = Duration(milliseconds: 700);
  static const scrollAxisBias = 1.15;

  /// 直播中区换台：竖直位移下限（逻辑像素）。
  static const liveFlingMinDy = 100.0;

  /// 直播中区换台：相对水平轴的最小夹角（度）。
  static const liveFlingMinAngleDeg = 70.0;

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

  /// 直播拖分区：横滑仅回看 seek；左右外区亮/音；中区竖滑留给抬手 fling 换台。
  static KotvFsMode classifyLiveDrag({
    required Offset total,
    required double downX,
    required double width,
    required bool catchup,
  }) {
    if (total.dx.abs() >= total.dy.abs()) {
      return catchup ? KotvFsMode.seek : KotvFsMode.none;
    }
    if (isLeftQuarter(downX, width)) {
      return supportsBrightness ? KotvFsMode.bright : KotvFsMode.none;
    }
    if (isRightQuarter(downX, width)) return KotvFsMode.volume;
    return KotvFsMode.channel;
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

  /// 直播滚轮：非回看时不做 seek，只保留音量。
  static KotvFsScrollKind classifyLiveScroll({
    required double dx,
    required double dy,
    required bool shift,
    required bool catchup,
  }) {
    final kind = classifyScroll(dx: dx, dy: dy, shift: shift);
    if (kind == KotvFsScrollKind.seek && !catchup) return KotvFsScrollKind.none;
    return kind;
  }

  /// 中区竖直甩动换台。返回相对「上键」同向的步进符号：负=上键语义、正=下键语义；不够则 null。
  /// 调用方再乘 [_liveInvert]：`delta: invert ? -sign : sign` 与遥控一致。
  static int? liveChannelFlingSign(Offset total) {
    final dx = total.dx.abs();
    final dy = total.dy;
    if (dy.abs() < liveFlingMinDy) return null;
    final angleDeg = math.atan2(dy.abs(), dx) * 180 / math.pi;
    if (angleDeg <= liveFlingMinAngleDeg) return null;
    // 手指上滑（dy < 0）→ 上键语义（默认上一台）。
    return dy < 0 ? -1 : 1;
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

  /// 捏合画面矩阵。用 [Matrix4.translate]/[Matrix4.scale]：Win7 钉 Flutter 3.19
  /// 无 `translateByDouble`/`scaleByDouble`；主线仍保留旧 API（仅弃用提示）。
  static Matrix4 pinchMatrix({
    required double tx,
    required double ty,
    required double scale,
  }) {
    final m = Matrix4.identity();
    // ignore: deprecated_member_use
    m.translate(tx, ty);
    // ignore: deprecated_member_use
    m.scale(scale, scale, 1.0);
    return m;
  }

  /// 抬手三分区：左 28% / 中 44% / 右 28%。
  static int liveTapZone(double x, double width) {
    if (width <= 0) return 1;
    final t = x / width;
    if (t < 0.28) return 0;
    if (t > 0.72) return 2;
    return 1;
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
