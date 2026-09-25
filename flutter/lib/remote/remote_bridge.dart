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
  /// 遥控推送的本地/URL 字幕文件。
  void Function(String path)? onSubtitleFile;
  /// 遥控推送的弹幕文件（本地路径或 URL）。
  void Function(String path)? onDanmakuFile;
  /// 遥控即时弹幕文本。
  void Function(String text)? onLiveDanmaku;

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
      final refreshes = (data['refreshes'] as List?) ?? const [];
      for (final r in refreshes) {
        if (r is! Map) continue;
        final typ = '${r['type'] ?? ''}'.trim().toLowerCase();
        final path = '${r['path'] ?? ''}'.trim();
        if (path.isEmpty) continue;
        if (typ == 'subtitle') {
          onSubtitleFile?.call(path);
        } else if (typ == 'danmaku') {
          onDanmakuFile?.call(path);
        }
      }
      final live = (data['danmakuLive'] as List?) ?? const [];
      for (final t in live) {
        final text = '$t'.trim();
        if (text.isNotEmpty) onLiveDanmaku?.call(text);
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
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((e) => VodItem.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> push(VodItem item) async {
    if (item.id.isEmpty) return;
    try {
      final p = await SharedPreferences.getInstance();
      // 无痕：不写本地历史；与引擎 settings.incognito 一致（启动后改设置需重启或走引擎）。
      final eng = p.getString('kotv_incognito');
      if (eng == 'true') return;
    } catch (_) {}
    final cur = await list();
    cur.removeWhere((e) => e.id == item.id && e.site == item.site);
    cur.insert(0, item);
    final trimmed = cur.take(60).toList();
    await _persist(trimmed);
  }

  /// 详情返回真实 id 后迁移键；若新键已存在则去掉旧条目。
  static Future<void> replaceId({
    required String site,
    required String oldId,
    required String newId,
  }) async {
    if (oldId.isEmpty || newId.isEmpty || oldId == newId) return;
    final cur = await list();
    final oldIdx = cur.indexWhere((e) => e.id == oldId && e.site == site);
    if (oldIdx < 0) return;
    final newIdx = cur.indexWhere((e) => e.id == newId && e.site == site);
    if (newIdx >= 0) {
      cur.removeAt(oldIdx);
      await _persist(cur);
      return;
    }
    final e = cur[oldIdx];
    cur[oldIdx] = VodItem(
      id: newId,
      name: e.name,
      pic: e.pic,
      remarks: e.remarks,
      typeName: e.typeName,
      site: e.site,
      flag: e.flag,
      positionMs: e.positionMs,
      durationMs: e.durationMs,
    );
    await _persist(cur);
  }

  static Future<void> _persist(List<VodItem> items) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
      _key,
      jsonEncode(items
          .map((e) => {
                'vod_id': e.id,
                'vod_name': e.name,
                'vod_pic': e.pic,
                'vod_remarks': e.remarks,
                'type_name': e.typeName,
                'site': e.site,
                if (e.flag.trim().isNotEmpty) 'vod_flag': e.flag,
                if (e.positionMs > 0) 'position': e.positionMs,
                if (e.durationMs > 0) 'duration': e.durationMs,
              })
          .toList()),
    );
  }

  /// 同步协议 History JSON（site$$$id）。
  static List<Map<String, dynamic>> toSyncTargets(List<VodItem> items) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return [
      for (final e in items)
        if (e.id.isNotEmpty)
          {
            'key': '${e.site}\$\$\$${e.id}',
            'vodPic': e.pic,
            'vodName': e.name,
            'vodFlag': e.flag,
            'vodRemarks': e.remarks,
            'createTime': now,
            'position': e.positionMs,
            'duration': e.durationMs,
            'speed': 1.0,
            'opening': 0,
            'ending': 0,
          },
    ];
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
    await _persist(cur);
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

/// 详情集列表倒序偏好，按 vodId@site 本地持久化。
class LocalRevSort {
  static String _key(String id, String site) => 'kotv_rev_${site}_$id';

  static Future<bool> get(String id, String site) async {
    if (id.isEmpty) return false;
    final p = await SharedPreferences.getInstance();
    return p.getBool(_key(id, site)) ?? false;
  }

  static Future<void> set(String id, String site, bool reversed) async {
    if (id.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_key(id, site), reversed);
  }
}

/// Flutter 页内播放器显示名。
String flutterPlayerLabel(String val) {
  final v = (val.trim().isEmpty ? kotvDefaultVodPlayer() : val.trim());
  switch (v) {
    case 'innie#html':
      return '浏览器 HTML5';
    case 'innie#art':
      return 'ArtPlayer';
    case 'innie#xg':
      return 'xgplayer';
    case 'innie#zw':
      return 'ZWPlayer';
    case 'innie#mpv':
      return '内置 MPV';
    case 'innie#exo':
      return '内置 ExoPlayer';
    case 'innie#fvp':
      return '内置 FVP';
    case 'outie#mpv':
      return '外部 MPV';
    case 'outie#vlc':
      return '外部 VLC';
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
