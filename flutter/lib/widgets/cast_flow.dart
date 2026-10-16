import 'dart:async';

import '../util/kotv_io.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/kotv_api.dart';
import '../theme/kotv_palette.dart';
import '../theme/stable_focus.dart';
import 'chrome.dart';

const _androidChannel = MethodChannel('kotv_android');

/// 上次成功投屏设备身份（protocol|name|detail），供再次打开列表标 ✓。
String? _lastCastDeviceKey;

String _castDeviceKey(Map d) {
  final protocol = '${d['protocol'] ?? ''}'.trim();
  final name = '${d['name'] ?? ''}'.trim();
  final detail = '${d['detail'] ?? ''}'.trim();
  return '$protocol|$name|$detail';
}

String _castDeviceLabel(Map d) {
  final label = '${d['label'] ?? ''}'.trim();
  if (label.isNotEmpty) return label;
  final name = '${d['name'] ?? ''}'.trim();
  return name.isEmpty ? '未知设备' : name;
}

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

/// 搜索 DLNA / Chromecast / 局域网 App 并投送当前引擎 MediaURL。
/// 弹窗内显示该设备投屏状态；成功后记住实际成功设备供下次标 ✓。取消返回 null。
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
  final devices = ((data['devices'] as List?) ?? []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  if (devices.isEmpty) {
    status('未发现投屏设备');
    showAppNews(context, '未发现设备。\n已搜索 DLNA / Chromecast / 局域网 App\n请确认设备与本机在同一局域网，并已授予投屏相关权限。');
    return '未发现投屏设备';
  }

  final result = await showDialog<String>(
    context: context,
    useRootNavigator: true,
    barrierDismissible: true,
    builder: (ctx) => _CastDeviceDialog(
      api: api,
      devices: devices,
      lastKey: _lastCastDeviceKey,
      onStatus: status,
      onCastSuccess: (key) => _lastCastDeviceKey = key,
    ),
  );
  if (result == null) {
    // 投屏进行中已禁止关闭；null 才是用户取消。
    status('已取消投屏');
    return null;
  }
  status(result);
  return result;
}

class _CastDeviceDialog extends StatefulWidget {
  const _CastDeviceDialog({
    required this.api,
    required this.devices,
    required this.lastKey,
    required this.onStatus,
    required this.onCastSuccess,
  });

  final KotvApi api;
  final List<Map<String, dynamic>> devices;
  final String? lastKey;
  final void Function(String msg) onStatus;
  final void Function(String key) onCastSuccess;

  @override
  State<_CastDeviceDialog> createState() => _CastDeviceDialogState();
}

class _CastDeviceDialogState extends State<_CastDeviceDialog> {
  /// 正在请求的行。
  int? _busyIndex;
  /// 显示状态文案的行（失败后仍保留，直至下次点击）。
  int? _statusIndex;
  String? _rowStatus;
  bool _rowOk = false;
  /// 投屏请求中或成功待关闭：禁止遮罩/返回误关。
  bool _blockPop = false;

  Future<void> _castAt(int i) async {
    if (_blockPop) return;
    final d = widget.devices[i];
    final index = int.tryParse('${d['index']}') ?? i;
    final label = _castDeviceLabel(d);
    setState(() {
      _blockPop = true;
      _busyIndex = i;
      _statusIndex = i;
      _rowStatus = '投屏中…';
      _rowOk = false;
    });
    widget.onStatus('正在投屏到 $label…');
    try {
      final cast = await widget.api.tools('cast', {'index': index});
      final msg = '${cast['message'] ?? '已投屏到 $label'}';
      // 以服务端实际成功设备为准（Chromecast 回退 DLNA 时 protocol/name/detail 会变）。
      final used = <String, dynamic>{
        'protocol': cast['protocol'] ?? d['protocol'],
        'name': cast['name'] ?? d['name'],
        'detail': cast['detail'] ?? d['detail'],
        'label': cast['label'] ?? d['label'],
      };
      final key = _castDeviceKey(used);
      var statusIdx = i;
      for (var j = 0; j < widget.devices.length; j++) {
        if (_castDeviceKey(widget.devices[j]) == key) {
          statusIdx = j;
          break;
        }
      }
      widget.onCastSuccess(key);
      if (!mounted) return;
      setState(() {
        _busyIndex = null;
        _statusIndex = statusIdx;
        _rowStatus = '已投屏';
        _rowOk = true;
      });
      widget.onStatus(msg);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (mounted) Navigator.of(context, rootNavigator: true).pop(msg);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _blockPop = false;
        _busyIndex = null;
        _statusIndex = i;
        _rowStatus = '失败：$e';
        _rowOk = false;
      });
      widget.onStatus('$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = KotvPalette.of(context);
    return PopScope(
      canPop: !_blockPop,
      child: SimpleDialog(
        backgroundColor: p.dialogBg,
        title: Text('投屏到', style: TextStyle(color: p.fg)),
        children: [
          for (var i = 0; i < widget.devices.length; i++)
            Builder(
              builder: (ctx) {
                final d = widget.devices[i];
                final key = _castDeviceKey(d);
                final label = _castDeviceLabel(d);
                final isLast = widget.lastKey != null && widget.lastKey == key;
                final showStatus = _statusIndex == i && _rowStatus != null;
                final trailing = showStatus
                    ? _rowStatus!
                    : (isLast ? '上次投屏' : '');
                final muted = _blockPop && _busyIndex != i;
                return KotvStableFocus(
                  autofocus: i == 0 && !_blockPop,
                  scrollIntoView: true,
                  onPressed: _blockPop ? null : () => unawaited(_castAt(i)),
                  borderRadius: 8,
                  child: Opacity(
                    opacity: muted ? 0.45 : 1,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              label + (isLast && !showStatus ? '  ✓' : ''),
                              style: TextStyle(
                                color: p.fg,
                                fontWeight: isLast || showStatus ? FontWeight.w700 : FontWeight.w500,
                              ),
                            ),
                          ),
                          if (trailing.isNotEmpty)
                            Flexible(
                              child: Text(
                                trailing,
                                textAlign: TextAlign.right,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: showStatus
                                      ? (_rowOk ? const Color(0xFF5CDB95) : p.primary)
                                      : p.muted,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}
