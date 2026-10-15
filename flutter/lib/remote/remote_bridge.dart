import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/kotv_api.dart';
import '../models/models.dart';
import '../player/kotv_platform.dart';
import 'engine_api.dart';

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
  /// 遥控 refresh type=live：重拉当前直播源频道表。
  void Function()? onLiveRefresh;
  /// 遥控 refresh type=detail：详情页重拉。
  void Function()? onDetailRefresh;
  /// 遥控 refresh type=player：点播重播当前集 / 直播重刷当前线。
  void Function()? onPlayerRefresh;
  /// 遥控 refresh type=category：首页/分类重载。
  void Function()? onCategoryRefresh;
  /// 投屏/推送打开：kind=play|detail。
  void Function(Map<String, dynamic> open)? onOpen;

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
        if (typ == 'live') {
          onLiveRefresh?.call();
          continue;
        }
        if (typ == 'detail') {
          onDetailRefresh?.call();
          continue;
        }
        if (typ == 'player') {
          onPlayerRefresh?.call();
          continue;
        }
        if (typ == 'category') {
          onCategoryRefresh?.call();
          continue;
        }
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
      final opens = (data['opens'] as List?) ?? const [];
      for (final o in opens) {
        if (o is! Map) continue;
        onOpen?.call(Map<String, dynamic>.from(o));
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


Future<KotvApi> _engineApi() => kotvEngineApi();

String _historyKey(String site, String id) {
  if (site.isEmpty) return id;
  return '$id@$site';
}

/// 观看历史：全部经引擎 /library（SQLite）；Flutter 只记引擎地址与鉴权。
class LocalHistory {
  static Future<List<VodItem>> list() async {
    final data = await (await _engineApi()).library('history');
    final raw = (data['items'] as List?) ?? const [];
    final items = <VodItem>[];
    for (final e in raw) {
      if (e is! Map) continue;
      final m = Map<String, dynamic>.from(e);
      final id = '${m['id'] ?? ''}'.trim();
      final site = '${m['site'] ?? ''}'.trim();
      if (id.isEmpty) continue;
      items.add(VodItem(
        id: id,
        name: '${m['name'] ?? ''}',
        pic: '${m['pic'] ?? ''}',
        remarks: '${m['remarks'] ?? ''}',
        site: site,
        flag: '${m['flag'] ?? ''}',
        positionMs: (m['position'] as num?)?.toInt() ?? 0,
        durationMs: (m['duration'] as num?)?.toInt() ?? 0,
      ));
    }
    return items;
  }

  static Future<bool> _incognito(KotvApi api) async {
    try {
      final s = await api.getSettings();
      final map = (s['settings'] as Map?) ?? const {};
      final v = '${map['incognito'] ?? ''}'.trim().toLowerCase();
      return v == 'true' || v == '1' || v == 'on';
    } catch (_) {
      return false;
    }
  }

  static Future<void> push(VodItem item) async {
    if (item.id.isEmpty) return;
    final api = await _engineApi();
    if (await _incognito(api)) return;
    var positionMs = item.positionMs;
    var durationMs = item.durationMs;
    if (positionMs <= 0) {
      try {
        for (final e in await list()) {
          if (e.id != item.id || e.site != item.site) continue;
          if (e.remarks != item.remarks || e.flag != item.flag) continue;
          if (e.positionMs <= 0) continue;
          positionMs = e.positionMs;
          durationMs = durationMs > 0 ? durationMs : e.durationMs;
          break;
        }
      } catch (_) {}
    }
    await api.libraryAction({
      'action': 'saveHistory',
      'item': {
        'key': _historyKey(item.site, item.id),
        'vodPic': item.pic,
        'vodName': item.name,
        'vodFlag': item.flag,
        'vodRemarks': item.remarks,
        if (item.site == 'push_agent') 'episodeUrl': item.id,
        'position': positionMs,
        'duration': durationMs,
        'speed': 1.0,
      },
    });
  }

  static Future<void> touchEpisode({
    required String id,
    required String name,
    required String pic,
    required String site,
    required String remarks,
    required String flag,
    String typeName = '',
  }) async {
    if (id.isEmpty) return;
    final api = await _engineApi();
    if (await _incognito(api)) return;
    var positionMs = 0;
    var durationMs = 0;
    try {
      for (final e in await list()) {
        if (e.id != id || e.site != site) continue;
        if (e.remarks == remarks && e.flag == flag) {
          positionMs = e.positionMs;
          durationMs = e.durationMs;
        }
        break;
      }
    } catch (_) {}
    await api.libraryAction({
      'action': 'saveHistory',
      'item': {
        'key': _historyKey(site, id),
        'vodPic': pic,
        'vodName': name,
        'vodFlag': flag,
        'vodRemarks': remarks,
        'position': positionMs,
        'duration': durationMs,
        'speed': 1.0,
      },
    });
  }

  static Future<void> replaceId({
    required String site,
    required String oldId,
    required String newId,
  }) async {
    if (oldId.isEmpty || newId.isEmpty || oldId == newId) return;
    try {
      await (await _engineApi()).libraryAction({
        'action': 'renameHistory',
        'key': _historyKey(site, oldId),
        'newKey': _historyKey(site, newId),
      });
    } catch (_) {}
  }

  static Future<void> clear() async {
    await (await _engineApi()).libraryAction({'action': 'clearHistory'});
  }

  static Future<void> remove(VodItem item) async {
    await (await _engineApi()).libraryAction({
      'action': 'deleteHistory',
      'key': _historyKey(item.site, item.id),
    });
  }
}

/// 片头/片尾偏移（秒）：写入引擎 history。
class LocalPlayOffsets {
  static Future<(int openingSec, int endingSec)> get(String id, String site) async {
    if (id.isEmpty) return (0, 0);
    try {
      final data = await (await _engineApi()).libraryAction({
        'action': 'getHistory',
        'key': _historyKey(site, id),
      });
      final item = data['item'];
      if (item is! Map) return (0, 0);
      final openMs = (item['opening'] as num?)?.toInt() ?? 0;
      final endMs = (item['ending'] as num?)?.toInt() ?? 0;
      return ((openMs ~/ 1000).clamp(0, 3600), (endMs ~/ 1000).clamp(0, 3600));
    } catch (_) {
      return (0, 0);
    }
  }

  static Future<void> set(String id, String site, int openingSec, int endingSec) async {
    if (id.isEmpty) return;
    try {
      await (await _engineApi()).libraryAction({
        'action': 'updateOffsets',
        'key': _historyKey(site, id),
        'opening': openingSec.clamp(0, 3600) * 1000,
        'ending': endingSec.clamp(0, 3600) * 1000,
      });
    } catch (_) {}
  }
}

/// 详情集列表倒序：写入引擎 history.rev_sort。
class LocalRevSort {
  static Future<bool> get(String id, String site) async {
    if (id.isEmpty) return false;
    try {
      final data = await (await _engineApi()).libraryAction({
        'action': 'getHistory',
        'key': _historyKey(site, id),
      });
      final item = data['item'];
      if (item is! Map) return false;
      final v = item['revSort'];
      return v == true || v == 1 || '$v' == '1';
    } catch (_) {
      return false;
    }
  }

  static Future<void> set(String id, String site, bool reversed) async {
    if (id.isEmpty) return;
    try {
      await (await _engineApi()).libraryAction({
        'action': 'setRevSort',
        'key': _historyKey(site, id),
        'revSort': reversed,
      });
    } catch (_) {}
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
