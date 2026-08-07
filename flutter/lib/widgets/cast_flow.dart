import '../util/kotv_io.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/kotv_api.dart';
import 'chrome.dart';
import 'dialogs.dart';

const _androidChannel = MethodChannel('kotv_android');

/// 高版本 Android 投屏前申请附近设备 / 定位（组播发现）权限。
Future<bool> ensureCastPermissions() async {
  if (kIsWeb || !Platform.isAndroid) return true;
  try {
    final ok = await _androidChannel.invokeMethod<bool>('ensureCastPermissions');
    return ok ?? true;
  } catch (_) {
    return true;
  }
}

/// 搜索 DLNA / Chromecast 并投送当前引擎 MediaURL。
/// 返回状态文案；取消返回 null。
Future<String?> runKotvCast(
  BuildContext context,
  KotvApi api, {
  void Function(String msg)? onStatus,
}) async {
  void status(String m) => onStatus?.call(m);

  final granted = await ensureCastPermissions();
  if (!granted) {
    status('需要附近设备/定位权限才能搜索投屏');
    if (context.mounted) {
      showAppNews(context, '投屏需要附近 Wi‑Fi 设备权限（Android 13+）或定位权限（旧版）。\n请在系统设置中允许后重试。');
    }
    return null;
  }

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
    showAppNews(context, '未发现设备。\n已搜索 DLNA / Chromecast\n请确认设备与本机在同一局域网，并已授予投屏相关权限。');
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
