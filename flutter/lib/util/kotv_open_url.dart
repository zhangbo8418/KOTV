import 'dart:io' show Platform, Process;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// 用系统方式打开 URL（外置浏览器 / Android View）。
/// OPENWEB 与站点 action 返回的 web.url 共用这一处，避免各处分叉。
Future<bool> kotvOpenExternalUrl(String raw) async {
  final s = raw.trim();
  if (s.isEmpty) return false;
  if (!kIsWeb && Platform.isAndroid) {
    try {
      final ok = await const MethodChannel('kotv_android')
          .invokeMethod<bool>('openView', {'url': s});
      if (ok == true) return true;
    } catch (_) {}
  }
  final uri = Uri.tryParse(s.contains(':') ? s : 'package:$s');
  if (uri == null || !uri.hasScheme) return false;
  if (!kIsWeb &&
      Platform.isAndroid &&
      (uri.scheme == 'package' || uri.scheme == 'intent')) {
    return false;
  }
  if (kIsWeb) {
    if (uri.scheme.toLowerCase() == 'javascript') return false;
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }
  try {
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (ok) return true;
  } catch (_) {}
  try {
    if (Platform.isMacOS) {
      return (await Process.run('open', [s])).exitCode == 0;
    } else if (Platform.isWindows) {
      // 勿用 `cmd /c start URL`：查询串里的 & 会被 cmd 当成命令分隔符截断。
      return (await Process.run(
              'rundll32', ['url.dll,FileProtocolHandler', s]))
          .exitCode ==
          0;
    } else if (Platform.isLinux) {
      return (await Process.run('xdg-open', [s])).exitCode == 0;
    }
  } catch (_) {}
  return false;
}
