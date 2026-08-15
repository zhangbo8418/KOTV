import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'kotv_platform.dart';

/// 桌面全屏：铺满当前窗口，或占满整块屏幕。
enum KotvDesktopFullscreenKind {
  /// 仅进入应用内全屏页/沉浸布局，不改系统窗口。
  window,

  /// 系统全屏，占满整块显示器。
  display,
}

Future<void> kotvEnterSystemFullscreen(KotvDesktopFullscreenKind kind) async {
  try {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  } catch (_) {}
  if (kind == KotvDesktopFullscreenKind.display && kotvIsDesktop()) {
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
  if (wasDisplayFullscreen && kotvIsDesktop()) {
    try {
      await windowManager.setFullScreen(false);
    } catch (_) {}
  }
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
