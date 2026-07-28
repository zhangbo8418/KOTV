import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import '../theme/layout_scale.dart';

/// YouTube 式迷你桌面播放：主界面收起，仅留置顶无边框悬浮小窗。
class MiniPlayerWindow {
  MiniPlayerWindow._();

  static bool get active => _active;
  static bool _active = false;
  static Size? _prevSize;
  static Offset? _prevPos;
  static bool _prevAlwaysOnTop = false;
  static bool _prevSkipTaskbar = false;

  static bool get supported =>
      !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  /// 16:9 悬浮窗（约 YouTube PiP 尺寸）。
  static const Size pipSize = Size(400, 256);

  static Future<void> enter({Size size = pipSize}) async {
    if (!supported || _active) return;
    try {
      _prevSize = await windowManager.getSize();
      _prevPos = await windowManager.getPosition();
      _prevAlwaysOnTop = await windowManager.isAlwaysOnTop();
      try {
        _prevSkipTaskbar = await windowManager.isSkipTaskbar();
      } catch (_) {
        _prevSkipTaskbar = false;
      }

      await windowManager.setMinimumSize(const Size(280, 180));
      await windowManager.unmaximize();

      // 无边框 + 置顶 = 桌面悬浮层（主窗口标题栏/边框消失）
      await windowManager.setAsFrameless();
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setHasShadow(true);
      await windowManager.setSkipTaskbar(false);
      await windowManager.setTitle('KO影视');
      await windowManager.setSize(size);
      await windowManager.setPosition(await _pipOrigin(size));
      await windowManager.show();
      await windowManager.focus();
      _active = true;
    } catch (e) {
      debugPrint('mini player enter failed: $e');
      // 失败时尽量恢复，避免卡在半状态
      try {
        await exit();
      } catch (_) {}
    }
  }

  static Future<Offset> _pipOrigin(Size size) async {
    try {
      final display = await screenRetriever.getPrimaryDisplay();
      final visible = display.visibleSize;
      final origin = display.visiblePosition ?? Offset.zero;
      if (visible != null) {
        // 右下角，类似 YouTube PiP
        return Offset(
          origin.dx + visible.width - size.width - 20,
          origin.dy + visible.height - size.height - 28,
        );
      }
    } catch (_) {}
    final pos = _prevPos ?? const Offset(80, 80);
    final prev = _prevSize ?? const Size(1280, 720);
    return Offset(
      (pos.dx + prev.width - size.width - 20).clamp(20.0, 4000.0),
      (pos.dy + prev.height - size.height - 28).clamp(20.0, 3000.0),
    );
  }

  static Future<void> exit() async {
    if (!supported) return;
    final wasActive = _active;
    try {
      // 恢复系统标题栏（撤销 frameless）
      await windowManager.setTitleBarStyle(
        TitleBarStyle.normal,
        windowButtonVisibility: true,
      );
      await windowManager.setAlwaysOnTop(_prevAlwaysOnTop);
      try {
        await windowManager.setSkipTaskbar(_prevSkipTaskbar);
      } catch (_) {}
      await windowManager.setMinimumSize(kotvMinWindowSize);
      if (_prevSize != null) {
        await windowManager.setSize(_prevSize!);
      } else {
        await windowManager.setSize(const Size(1280, 720));
      }
      if (_prevPos != null) {
        await windowManager.setPosition(_prevPos!);
      }
      await windowManager.setTitle('KO影视');
      await windowManager.setHasShadow(true);
      await windowManager.show();
      await windowManager.focus();
    } catch (e) {
      debugPrint('mini player exit failed: $e');
    } finally {
      if (wasActive || _active) {
        _active = false;
        _prevSize = null;
        _prevPos = null;
      }
    }
  }
}
