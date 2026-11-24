import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../theme/layout_scale.dart';
import 'fullscreen_sys.dart' if (dart.library.html) 'fullscreen_sys_web.dart' as sys;
import 'kotv_platform.dart';

/// 桌面/Web 全屏：铺满当前窗口，或占满整块屏幕。
enum KotvDesktopFullscreenKind {
  /// 仅进入应用内全屏页/沉浸布局，不改系统窗口 / 浏览器全屏。
  window,

  /// 系统全屏（桌面）或浏览器全屏（Web），占满整块显示器。
  display,
}

/// 沉浸布局已 setState 后调用：先等这一帧画完，再进系统全屏。
/// 详情 / 直播共用，避免各页各自写 endOfFrame + enter 时序漂移。
Future<void> kotvEnterSystemFullscreenAfterLayout(
  KotvDesktopFullscreenKind kind,
) async {
  await WidgetsBinding.instance.endOfFrame;
  await kotvEnterSystemFullscreen(kind);
}

Future<void> kotvEnterSystemFullscreen(KotvDesktopFullscreenKind kind) async {
  try {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  } catch (_) {}
  try {
    // 沉浸时去掉状态栏/导航栏对比色占位，避免仍像「顶上一条」。
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    );
  } catch (_) {}
  if (kind != KotvDesktopFullscreenKind.display) return;
  if (kIsWeb) {
    await sys.kotvEnterDisplayFullscreen();
    return;
  }
  if (!kotvIsDesktop()) return;
  // Windows：先等应用内布局落稳再 setFullScreen，避免和画面放大挤在同一帧。
  // 有边框不先最大化。子窗对齐客户区由 window_manager 补丁延后按条件重试。
  if (kotvIsWindows()) {
    try {
      if (await windowManager.isFullScreen()) return;
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 180));
    try {
      await WidgetsBinding.instance.endOfFrame;
    } catch (_) {}
  }
  try {
    await windowManager.setFullScreen(true);
  } catch (_) {}
}

/// 手机/平板的屏幕方向。
enum KotvPhoneOrientation {
  /// 跟随系统自动旋转：方向锁定时保持竖屏，关闭锁定时随手机转。
  follow,

  /// 横屏全屏：两个横向随手机翻转，方向锁定时也照转。
  landscape,

  /// 竖屏。
  portrait,
}

/// 手机/平板设方向（电视、桌面、Web 不处理）。Android 走原生 requestedOrientation：
/// 「横屏随重力、无视方向锁定」只有 SENSOR_LANDSCAPE 能表达，Flutter 的方向列表做不到。
Future<void> kotvSetPhoneOrientation(KotvPhoneOrientation orientation) async {
  if (kIsWeb || kotvIsDesktop() || KotvLayout.television) return;
  try {
    if (kotvIsAndroid()) {
      await const MethodChannel('kotv_android').invokeMethod<bool>('setOrientation', orientation.name);
      return;
    }
    await SystemChrome.setPreferredOrientations(switch (orientation) {
      KotvPhoneOrientation.follow => const [
          DeviceOrientation.portraitUp,
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ],
      KotvPhoneOrientation.landscape => const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ],
      KotvPhoneOrientation.portrait => const [DeviceOrientation.portraitUp],
    });
  } catch (_) {}
}

Future<void> kotvExitSystemFullscreen({required bool wasDisplayFullscreen}) async {
  try {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  } catch (_) {}
  try {
    if (KotvLayout.television) {
      await SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else if (!kIsWeb && !kotvIsDesktop()) {
      await kotvSetPhoneOrientation(KotvPhoneOrientation.follow);
    } else {
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    }
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

/// 仅「手机竖屏握持 + 横屏片源」时显示「全屏观看」。
/// 竖屏片、方片、尺寸未出（加载中）都不显示。
bool kotvShouldShowForceLandscape({
  required Size screen,
  required int videoWidth,
  required int videoHeight,
}) {
  if (kotvIsDesktop()) return false;
  final phonePortrait = screen.height > screen.width;
  if (!phonePortrait) return false;
  if (videoWidth <= 0 || videoHeight <= 0) return false;
  return videoWidth > videoHeight;
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
