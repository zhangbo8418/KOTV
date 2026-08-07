import 'dart:async';
import '../util/kotv_io.dart';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import '../theme/layout_scale.dart';

/// 迷你播放：桌面为置顶无边框小窗；Android 为系统画中画（PiP）。
class MiniPlayerWindow {
  MiniPlayerWindow._();

  static const _android = MethodChannel('kotv_android');

  static bool get active => _active;
  static bool _active = false;
  static Size? _prevSize;
  static Offset? _prevPos;
  static bool _prevAlwaysOnTop = false;
  static bool _prevSkipTaskbar = false;

  static bool get supported =>
      !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux || Platform.isAndroid);

  /// 16:9 悬浮窗（约 YouTube PiP 尺寸）。
  static const Size pipSize = Size(400, 256);

  /// Android PiP 进出回调（系统手势扩大/关闭小窗时通知 UI）。
  static void Function(bool inPip)? onAndroidPipChanged;

  static bool get _isDesktop =>
      !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  static Future<void> enter({Size size = pipSize}) async {
    if (!supported || _active) return;
    if (Platform.isAndroid) {
      await _enterAndroidPip();
      return;
    }
    if (!_isDesktop) return;
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
      try {
        await exit();
      } catch (_) {}
    }
  }

  static Future<void> _enterAndroidPip() async {
    try {
      final ok = await _android.invokeMethod<bool>('enterPip') ?? false;
      if (ok) _active = true;
    } catch (e) {
      debugPrint('android pip enter failed: $e');
    }
  }

  static Future<Offset> _pipOrigin(Size size) async {
    try {
      final display = await screenRetriever.getPrimaryDisplay();
      final visible = display.visibleSize;
      final origin = display.visiblePosition ?? Offset.zero;
      if (visible != null) {
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
    if (Platform.isAndroid) {
      // 系统 PiP 由用户点扩大退出；此处只复位状态
      _active = false;
      return;
    }
    if (!_isDesktop) return;
    final wasActive = _active;
    try {
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

  /// 在 main 里调用一次，监听系统 PiP 模式变化。
  static void bindAndroidPipListener() {
    if (kIsWeb || !Platform.isAndroid) return;
    _android.setMethodCallHandler((call) async {
      if (call.method == 'onPipChanged') {
        final inPip = call.arguments == true;
        _active = inPip;
        onAndroidPipChanged?.call(inPip);
      }
      return null;
    });
  }
}
