import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/kotv_api.dart';
import '../models/models.dart';
import '../player/kotv_platform.dart';

/// 轮询 Go 引擎遥控队列，并把播放状态回写给遥控页。
class RemoteBridge {
  RemoteBridge(this.api);

  final KotvApi api;
  Timer? _timer;
  Timer? _pingTimer;
  void Function(String type, int seekMs)? onControl;
  void Function(String keyword)? onSearch;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 700), (_) => _tick());
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      try {
        await api.sessionPing();
      } catch (_) {}
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _pingTimer?.cancel();
    _pingTimer = null;
  }

  Future<void> _tick() async {
    try {
      final data = await api.remotePoll();
      final controls = (data['controls'] as List?) ?? const [];
      for (final c in controls) {
        if (c is! Map) continue;
        final type = '${c['type'] ?? ''}';
        final seek = (c['seekMs'] is num) ? (c['seekMs'] as num).toInt() : 0;
        onControl?.call(type, seek);
      }
      final searches = (data['searches'] as List?) ?? const [];
      for (final s in searches) {
        final kw = '$s'.trim();
        if (kw.isNotEmpty) onSearch?.call(kw);
      }
    } catch (e) {
      debugPrint('remote poll: $e');
    }
  }

  Future<void> reportMedia({
    required String state,
    required String title,
    String url = '',
    int positionMs = 0,
    int durationMs = 0,
  }) async {
    try {
      await api.setMedia({
        'state': state,
        'title': title,
        'url': url,
        'position': '$positionMs',
        'duration': '$durationMs',
      });
    } catch (_) {}
  }
}

/// 本机观看历史（取舍：不先做 Go DB 同步）。
class LocalHistory {
  static const _key = 'kotv_history_v1';

  static Future<List<VodItem>> list() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    final list = (jsonDecode(raw) as List)
        .whereType<Map>()
        .map((e) => VodItem.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    return list;
  }

  static Future<void> push(VodItem item) async {
    if (item.id.isEmpty) return;
    try {
      final p = await SharedPreferences.getInstance();
      // 无痕：不写本地历史；与引擎 settings.incognito 对齐（启动后改设置需重启或走引擎）。
      final eng = p.getString('kotv_incognito');
      if (eng == 'true') return;
    } catch (_) {}
    final cur = await list();
    cur.removeWhere((e) => e.id == item.id && e.site == item.site);
    cur.insert(0, item);
    final trimmed = cur.take(60).toList();
    final p = await SharedPreferences.getInstance();
    await p.setString(
      _key,
      jsonEncode(trimmed
          .map((e) => {
                'vod_id': e.id,
                'vod_name': e.name,
                'vod_pic': e.pic,
                'vod_remarks': e.remarks,
                'type_name': e.typeName,
                'site': e.site,
              })
          .toList()),
    );
  }

  static Future<void> setIncognito(bool on) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('kotv_incognito', on ? 'true' : 'false');
  }

  static Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_key);
  }

  static Future<void> remove(VodItem item) async {
    final cur = await list();
    cur.removeWhere((e) => e.id == item.id && e.site == item.site);
    final p = await SharedPreferences.getInstance();
    await p.setString(
      _key,
      jsonEncode(cur
          .map((e) => {
                'vod_id': e.id,
                'vod_name': e.name,
                'vod_pic': e.pic,
                'vod_remarks': e.remarks,
                'type_name': e.typeName,
                'site': e.site,
              })
          .toList()),
    );
  }
}

/// 片头/片尾偏移（秒），按 vodId@site 本地持久化。
class LocalPlayOffsets {
  static String _key(String id, String site) => 'kotv_off_${site}_$id';

  static Future<(int openingSec, int endingSec)> get(String id, String site) async {
    if (id.isEmpty) return (0, 0);
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_key(id, site));
    if (raw == null || raw.isEmpty) return (0, 0);
    try {
      final m = jsonDecode(raw) as Map;
      final open = (m['opening'] is num) ? (m['opening'] as num).toInt() : 0;
      final end = (m['ending'] is num) ? (m['ending'] as num).toInt() : 0;
      return (open.clamp(0, 3600), end.clamp(0, 3600));
    } catch (_) {
      return (0, 0);
    }
  }

  static Future<void> set(String id, String site, int openingSec, int endingSec) async {
    if (id.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    await p.setString(
      _key(id, site),
      jsonEncode({
        'opening': openingSec.clamp(0, 3600),
        'ending': endingSec.clamp(0, 3600),
      }),
    );
  }
}

/// Flutter 页内播放器显示名。
String flutterPlayerLabel(String val) {
  final v = val.trim().isEmpty ? kotvDefaultVodPlayer() : val.trim();
  switch (v) {
    case 'innie#vlc':
      return '内置 VLC';
    case 'innie#mpv':
      return '内置 MPV';
    case 'innie#exo':
      return '内置 ExoPlayer';
    case 'innie#ijk':
      return '内置 ijk';
    case 'outie#vlc':
      return '外部 VLC';
    case 'outie#mpv':
      return '外部 MPV';
    case 'outie#iina':
      return 'IINA';
    default:
      return v;
  }
}

bool flutterIsEmbedPlayer(String val) {
  final v = val.trim();
  return v.isEmpty || v.startsWith('innie#');
}
