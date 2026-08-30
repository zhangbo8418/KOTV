import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'fullscreen_sys.dart' if (dart.library.html) 'fullscreen_sys_web.dart' as sys;
import 'kotv_platform.dart';

/// 桌面/Web 全屏：铺满当前窗口，或占满整块屏幕。
enum KotvDesktopFullscreenKind {
  /// 仅进入应用内全屏页/沉浸布局，不改系统窗口 / 浏览器全屏。
  window,

  /// 系统全屏（桌面）或浏览器全屏（Web），占满整块显示器。
  display,
}

Future<void> kotvEnterSystemFullscreen(KotvDesktopFullscreenKind kind) async {
  try {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  } catch (_) {}
  if (kind != KotvDesktopFullscreenKind.display) return;
  if (kIsWeb) {
    await sys.kotvEnterDisplayFullscreen();
    return;
  }
  if (kotvIsDesktop()) {
    try {
      await windowManager.setFullScreen(true);
    } catch (_) {}
  }
}

Future<void> kotvExitSystemFullscreen({required bool wasDisplayFullscreen}) async {
  try {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  } catch (_) {}
  try {
    await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
  } catch (_) {}
  if (!wasDisplayFullscreen) return;
  if (kIsWeb) {
    await sys.kotvExitDisplayFullscreen();
    return;
  }
  if (kotvIsDesktop()) {
    try {
      await windowManager.setFullScreen(false);
    } catch (_) {}
  }
}

Future<void> kotvLockPortrait() async {
  try {
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
    ]);
  } catch (_) {}
}

Future<void> kotvForceLandscape() async {
  try {
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  } catch (_) {}
}

/// 竖屏设备 + 横屏画面时，显示「全屏观看」强制横屏。
bool kotvShouldShowForceLandscape({
  required Size screen,
  required int videoWidth,
  required int videoHeight,
}) {
  if (kotvIsDesktop()) return false;
  final portrait = screen.height > screen.width;
  if (!portrait) return false;
  if (videoWidth > 0 && videoHeight > 0) {
    return videoWidth >= videoHeight;
  }
  // 未知尺寸时按横屏片处理（点播多数如此）。
  return true;
}

/// BoxFit.contain 下视频实际绘制区域（用于把控件放到 letterbox 黑边）。
Rect kotvVideoContainRect({
  required Size screen,
  required int videoWidth,
  required int videoHeight,
}) {
  var vw = videoWidth.toDouble();
  var vh = videoHeight.toDouble();
  if (vw <= 0 || vh <= 0) {
    vw = 16;
    vh = 9;
  }
  final scale = math.min(screen.width / vw, screen.height / vh);
  final dw = vw * scale;
  final dh = vh * scale;
  return Rect.fromLTWH(
    (screen.width - dw) / 2,
    (screen.height - dh) / 2,
    dw,
    dh,
  );
}
