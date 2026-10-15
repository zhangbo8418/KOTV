import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../api/kotv_api.dart';
import '../models/models.dart';
import 'sync_import_apply.dart';

Future<KotvApi> _engineApi() async {
  final p = await SharedPreferences.getInstance();
  final base = (p.getString('engine_base_url') ?? '').trim();
  return KotvApi(baseUrl: base.isEmpty ? 'http://127.0.0.1:9978' : base);
}

String _keepKey(String site, String id) {
  if (site.isEmpty) return id;
  return '$site\$\$\$$id';
}

/// 点播收藏：全部经引擎 /library（SQLite）；Flutter 只记引擎地址与鉴权。
class LocalCollect {
  static Map<String, dynamic> _keepBody(VodItem item) {
    return {
      'key': _keepKey(item.site, item.id),
      'vodPic': item.pic,
      'vodName': item.name,
      'vodFlag': item.flag,
      'vodRemarks': item.remarks,
      'type': 0,
      'cid': 0,
      'siteName': item.configSource.trim().isNotEmpty ? item.configSource.trim() : item.site,
    };
  }

  static Future<List<VodItem>> list() async {
    final data = await (await _engineApi()).library('keep');
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
        configSource: '${m['siteName'] ?? ''}',
      ));
    }
    return items;
  }

  static Future<bool> isKept(String id, String site, {String configSource = ''}) async {
    if (id.isEmpty) return false;
    try {
      final items = await list();
      final cs = configSource.trim();
      if (cs.isNotEmpty) {
        final exact = items.any(
          (e) => e.id == id && e.site == site && e.configSource.trim() == cs,
        );
        if (exact) return true;
      }
      return items.any((e) => e.id == id && e.site == site);
    } catch (_) {
      return false;
    }
  }

  static Future<bool> toggle(VodItem item) async {
    if (item.id.isEmpty) return false;
    final data = await (await _engineApi()).libraryAction({
      'action': 'toggleKeep',
      'keep': _keepBody(item),
    });
    return data['kept'] == true;
  }

  /// 详情返回真实 id 后迁移键；若新键已存在则去掉旧条目。
  static Future<void> replaceId({
    required String site,
    required String oldId,
    required String newId,
    String configSource = '',
  }) async {
    if (oldId.isEmpty || newId.isEmpty || oldId == newId) return;
    final api = await _engineApi();
    try {
      final cur = await list();
      VodItem? old;
      for (final e in cur) {
        if (e.id == oldId && e.site == site) {
          if (configSource.trim().isEmpty || e.configSource.trim() == configSource.trim() || e.configSource.trim().isEmpty) {
            old = e;
            break;
          }
        }
      }
      if (old == null) return;
      final hasNew = cur.any((e) => e.id == newId && e.site == site);
      await api.libraryAction({'action': 'deleteKeep', 'key': _keepKey(site, oldId)});
      if (hasNew) return;
      await api.libraryAction({
        'action': 'saveKeep',
        'keep': _keepBody(VodItem(
          id: newId,
          name: old.name,
          pic: old.pic,
          remarks: old.remarks,
          site: site,
          flag: old.flag,
          configSource: configSource.trim().isNotEmpty ? configSource : old.configSource,
        )),
      });
    } catch (_) {}
  }

  /// 已收藏时用详情最新 name/pic 等回写展示字段。
  static Future<void> updateMeta({
    required String id,
    required String site,
    String configSource = '',
    String? name,
    String? pic,
    String? remarks,
    String? typeName,
  }) async {
    if (id.isEmpty) return;
    try {
      final cur = await list();
      final i = cur.indexWhere((e) {
        if (e.id != id || e.site != site) return false;
        final cs = configSource.trim();
        if (cs.isEmpty) return true;
        return e.configSource.trim() == cs || e.configSource.trim().isEmpty;
      });
      if (i < 0) return;
      final e = cur[i];
      await (await _engineApi()).libraryAction({
        'action': 'saveKeep',
        'keep': _keepBody(VodItem(
          id: id,
          name: (name != null && name.isNotEmpty) ? name : e.name,
          pic: (pic != null && pic.isNotEmpty) ? pic : e.pic,
          remarks: remarks ?? e.remarks,
          typeName: typeName ?? e.typeName,
          site: site,
          flag: e.flag,
          configSource: configSource.isNotEmpty ? configSource : e.configSource,
        )),
      });
    } catch (_) {}
  }

  static Future<void> clear() async {
    await (await _engineApi()).libraryAction({'action': 'clearKeep'});
  }

  static Future<void> remove(VodItem item) async {
    await (await _engineApi()).libraryAction({
      'action': 'deleteKeep',
      'key': _keepKey(item.site, item.id),
    });
  }

  static Future<void> replaceAll(List<VodItem> items) async {
    await (await _engineApi()).tools('mirrorSync', {
      'keep': jsonEncode(toSyncTargets(items.take(200).toList())),
    });
  }

  /// 同步协议 Keep JSON（site$$$id）。
  static List<Map<String, dynamic>> toSyncTargets(List<VodItem> items) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return [
      for (final e in items)
        if (e.id.isNotEmpty)
          {
            'key': _keepKey(e.site, e.id),
            'vodPic': e.pic,
            'vodName': e.name,
            'vodFlag': e.flag,
            'vodRemarks': e.remarks,
            'createTime': now,
            'type': 0,
            'cid': 0,
            'siteName': e.configSource.trim().isNotEmpty ? e.configSource.trim() : e.site,
          },
    ];
  }

  static List<VodItem> fromSyncTargets(String raw) {
    final out = <VodItem>[];
    for (final j in decodeSyncList(raw)) {
      var site = '';
      var id = '';
      parseSyncVodKey('${j['key'] ?? ''}', (s, i) {
        site = s;
        id = i;
      });
      if (id.isEmpty) {
        final sn = '${j['siteName'] ?? ''}'.trim();
        if (sn.isNotEmpty) site = sn;
      }
      if (id.isEmpty) continue;
      out.add(VodItem(
        id: id,
        name: '${j['vodName'] ?? ''}',
        pic: '${j['vodPic'] ?? ''}',
        remarks: '${j['vodRemarks'] ?? ''}',
        site: site,
        flag: '${j['vodFlag'] ?? ''}',
        configSource: '${j['config_source'] ?? j['configSource'] ?? j['siteName'] ?? ''}',
      ));
    }
    return out;
  }
}
