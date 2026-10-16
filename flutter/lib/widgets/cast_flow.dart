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

/// 搜索设备并投送；弹窗显示投屏中/可断开；成功返回状态文案，取消返回 null。
/// [positionMs] 为本机播放进度，投到电视时用于续看。
Future<String?> runKotvCast(
  BuildContext context,
  KotvApi api, {
  void Function(String msg)? onStatus,
  int? positionMs,
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
  Map<String, dynamic> session = const {};
  try {
    final results = await Future.wait([
      api.tools('castDiscover'),
      api.tools('castStatus').catchError((_) => <String, dynamic>{'ok': true, 'active': false}),
    ]);
    data = results[0];
    session = results[1];
  } catch (e) {
    status('$e');
    if (context.mounted) showAppNews(context, '搜索失败\n$e');
    return null;
  }
  if (!context.mounted) return null;
  final devices = ((data['devices'] as List?) ?? []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  final active = session['active'] == true;
  final activeKey = active ? '${session['key'] ?? ''}'.trim() : '';

  if (devices.isEmpty && !active) {
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
      activeKey: activeKey,
      activeLabel: active ? '${session['label'] ?? session['name'] ?? ''}'.trim() : '',
      onStatus: status,
      positionMs: positionMs,
    ),
  );
  if (result == null) {
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
    required this.activeKey,
    required this.activeLabel,
    required this.onStatus,
    this.positionMs,
  });

  final KotvApi api;
  final List<Map<String, dynamic>> devices;
  final String activeKey;
  final String activeLabel;
  final void Function(String msg) onStatus;
  final int? positionMs;

  @override
  State<_CastDeviceDialog> createState() => _CastDeviceDialogState();
}

class _CastDeviceDialogState extends State<_CastDeviceDialog> {
  late String _activeKey = widget.activeKey;
  late String _activeLabel = widget.activeLabel;
  int? _busyIndex;
  int? _statusIndex;
  String? _rowStatus;
  bool _rowOk = false;
  bool _blockPop = false;
  bool _stopping = false;

  Future<void> _castAt(int i) async {
    if (_blockPop || _stopping) return;
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
      final params = <String, dynamic>{'index': index};
      final pos = widget.positionMs;
      if (pos != null && pos > 0) params['positionMs'] = pos;
      final cast = await widget.api.tools('cast', params);
      final msg = '${cast['message'] ?? '已投屏到 $label'}';
      final key = '${cast['key'] ?? ''}'.trim().isNotEmpty
          ? '${cast['key']}'.trim()
          : _castDeviceKey({
              'protocol': cast['protocol'] ?? d['protocol'],
              'name': cast['name'] ?? d['name'],
              'detail': cast['detail'] ?? d['detail'],
            });
      var statusIdx = i;
      for (var j = 0; j < widget.devices.length; j++) {
        if (_castDeviceKey(widget.devices[j]) == key) {
          statusIdx = j;
          break;
        }
      }
      if (!mounted) return;
      setState(() {
        _busyIndex = null;
        _statusIndex = statusIdx;
        _rowStatus = '已投屏';
        _rowOk = true;
        _activeKey = key;
        _activeLabel = '${cast['label'] ?? label}'.trim();
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

  Future<void> _stopCast() async {
    if (_blockPop || _stopping) return;
    setState(() {
      _stopping = true;
      _blockPop = true;
      _rowStatus = '断开中…';
      _rowOk = false;
      if (_activeKey.isNotEmpty) {
        for (var j = 0; j < widget.devices.length; j++) {
          if (_castDeviceKey(widget.devices[j]) == _activeKey) {
            _statusIndex = j;
            break;
          }
        }
      }
    });
    widget.onStatus('正在断开投屏…');
    try {
      final r = await widget.api.tools('castStop');
      final msg = '${r['message'] ?? '已断开投屏'}';
      if (!mounted) return;
      setState(() {
        _activeKey = '';
        _activeLabel = '';
        _rowStatus = '已断开';
        _rowOk = true;
        _stopping = false;
        _blockPop = false;
        _busyIndex = null;
      });
      widget.onStatus(msg);
      if (mounted) Navigator.of(context, rootNavigator: true).pop(msg);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stopping = false;
        _blockPop = false;
        _rowStatus = '断开失败：$e';
        _rowOk = false;
      });
      widget.onStatus('$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = KotvPalette.of(context);
    final hasActive = _activeKey.isNotEmpty;
    final activeInList = hasActive && widget.devices.any((d) => _castDeviceKey(d) == _activeKey);

    return PopScope(
      canPop: !_blockPop,
      child: SimpleDialog(
        backgroundColor: p.dialogBg,
        title: Text('投屏到', style: TextStyle(color: p.fg)),
        children: [
          if (hasActive) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                activeInList ? '当前投屏：$_activeLabel' : '当前投屏：$_activeLabel（未在列表中）',
                style: TextStyle(color: p.muted, fontSize: 13),
              ),
            ),
            KotvStableFocus(
              autofocus: !_blockPop && widget.devices.isEmpty,
              onPressed: _blockPop ? null : () => unawaited(_stopCast()),
              borderRadius: 8,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                child: Text(
                  _stopping ? '断开中…' : '断开投屏',
                  style: TextStyle(color: p.primary, fontWeight: FontWeight.w700),
                ),
              ),
            ),
            const Divider(height: 12),
          ],
          if (widget.devices.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
              child: Text('未发现其它设备', style: TextStyle(color: p.muted)),
            ),
          for (var i = 0; i < widget.devices.length; i++)
            Builder(
              builder: (ctx) {
                final d = widget.devices[i];
                final key = _castDeviceKey(d);
                final label = _castDeviceLabel(d);
                final isActive = hasActive && key == _activeKey;
                final showStatus = _statusIndex == i && _rowStatus != null;
                final trailing = showStatus
                    ? _rowStatus!
                    : (isActive ? '投屏中' : '');
                final muted = _blockPop && _busyIndex != i;
                return KotvStableFocus(
                  autofocus: i == 0 && !_blockPop && !hasActive,
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
                              label,
                              style: TextStyle(
                                color: p.fg,
                                fontWeight: isActive || showStatus ? FontWeight.w700 : FontWeight.w500,
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
                                      : p.primary,
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
