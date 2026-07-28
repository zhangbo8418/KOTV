import 'package:flutter/material.dart';

import '../api/kotv_api.dart';
import 'chrome.dart';
import 'dialogs.dart';

/// 搜索 DLNA / Chromecast 并投送当前引擎 MediaURL。
/// 返回状态文案；取消返回 null。
Future<String?> runKotvCast(
  BuildContext context,
  KotvApi api, {
  void Function(String msg)? onStatus,
}) async {
  void status(String m) => onStatus?.call(m);
  status('正在搜索投屏设备…');
  Map<String, dynamic> data;
  try {
    data = await api.tools('castDiscover');
  } catch (e) {
    status('$e');
    if (context.mounted) showAppNews(context, '搜索失败\n$e');
    return null;
  }
  if (!context.mounted) return null;
  final devices = ((data['devices'] as List?) ?? []).whereType<Map>().toList();
  if (devices.isEmpty) {
    status('未发现投屏设备');
    showAppNews(context, '未发现设备。\n已搜索 DLNA / Chromecast\n请确认设备与本机在同一局域网。');
    return '未发现投屏设备';
  }
  final opts = <(String, String)>[
    for (final d in devices) ('${d['label'] ?? d['name']}', '${d['index']}'),
  ];
  final picked = await pickChoice(context, title: '投屏到', current: '', options: opts);
  if (picked == null || !context.mounted) {
    status('已取消投屏');
    return null;
  }
  status('正在投屏…');
  try {
    final cast = await api.tools('cast', {'index': int.tryParse(picked) ?? -1});
    final msg = '${cast['message'] ?? '已投屏'}';
    status(msg);
    if (context.mounted) showAppNews(context, msg);
    return msg;
  } catch (e) {
    status('$e');
    if (context.mounted) showAppNews(context, '投屏失败\n$e');
    return null;
  }
}
