import 'dart:io' show Platform, Process;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// OPENWEB 次数戳：详情加载期间若递增，说明站源已用开网页表达意图（如配置页），
/// 空线路不应再拿标题去全网精搜。仅 [kotvNoteOpenWeb] 推进，勿绑到任意外链打开。
int _kotvOpenWebStamp = 0;

/// 当前 OPENWEB 次数戳（详情加载开头记下，供空线路门禁比对）。
int kotvOpenWebStamp() => _kotvOpenWebStamp;

/// 自 [stamp] 以来是否又收到过 OPENWEB。
bool kotvOpenWebSince(int stamp) => _kotvOpenWebStamp > stamp;

/// 记录一次 OPENWEB（由 PostMsg 投递处调用）。
void kotvNoteOpenWeb() => _kotvOpenWebStamp++;

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
