import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Web：浏览器 Fullscreen API（对应桌面 windowManager 真全屏）。
Future<void> kotvEnterDisplayFullscreen() async {
  final el = web.document.documentElement;
  if (el == null) return;
  try {
    final cur = web.document.fullscreenElement;
    if (cur != null) return;
    await el.requestFullscreen().toDart;
  } catch (_) {}
}

Future<void> kotvExitDisplayFullscreen() async {
  try {
    if (web.document.fullscreenElement == null) return;
    await web.document.exitFullscreen().toDart;
  } catch (_) {}
}
