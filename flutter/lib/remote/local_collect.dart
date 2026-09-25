import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';

class LocalCollect {
  static const _key = 'kotv_collect_v1';

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

  /// 去重：优先 (configSource, site, id)；configSource 空时兼容旧条目。
  static int _indexOf(
    List<VodItem> cur, {
    required String id,
    required String site,
    String configSource = '',
  }) {
    final cs = configSource.trim();
    final exact = cur.indexWhere(
      (e) => e.id == id && e.site == site && e.configSource.trim() == cs,
    );
    if (exact >= 0) return exact;
    if (cs.isNotEmpty) {
      return cur.indexWhere(
        (e) => e.id == id && e.site == site && e.configSource.trim().isEmpty,
      );
    }
    return cur.indexWhere((e) => e.id == id && e.site == site);
  }

  static Future<bool> isKept(String id, String site, {String configSource = ''}) async {
    final list = await LocalCollect.list();
    return _indexOf(list, id: id, site: site, configSource: configSource) >= 0;
  }

  static Future<bool> toggle(VodItem item) async {
    final cur = await list();
    final i = _indexOf(cur, id: item.id, site: item.site, configSource: item.configSource);
    if (i >= 0) {
      cur.removeAt(i);
      await _save(cur);
      return false;
    }
    cur.insert(0, item);
    await _save(cur.take(200).toList());
    return true;
  }

  /// 详情返回真实 id 后迁移键；若新键已存在则去掉旧条目。
  static Future<void> replaceId({
    required String site,
    required String oldId,
    required String newId,
    String configSource = '',
  }) async {
    if (oldId.isEmpty || newId.isEmpty || oldId == newId) return;
    final cur = await list();
    final oldIdx = _indexOf(cur, id: oldId, site: site, configSource: configSource);
    if (oldIdx < 0) return;
    final newIdx = _indexOf(cur, id: newId, site: site, configSource: configSource);
    if (newIdx >= 0) {
      cur.removeAt(oldIdx);
      await _save(cur);
      return;
    }
    final e = cur[oldIdx];
    cur[oldIdx] = _copy(e, id: newId);
    await _save(cur);
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
    final cur = await list();
    final i = _indexOf(cur, id: id, site: site, configSource: configSource);
    if (i < 0) return;
    final e = cur[i];
    cur[i] = _copy(
      e,
      name: (name != null && name.isNotEmpty) ? name : null,
      pic: (pic != null && pic.isNotEmpty) ? pic : null,
      remarks: remarks,
      typeName: typeName,
      configSource: configSource.isNotEmpty ? configSource : null,
    );
    await _save(cur);
  }

  static Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_key);
  }

  static Future<void> remove(VodItem item) async {
    final cur = await list();
    final i = _indexOf(cur, id: item.id, site: item.site, configSource: item.configSource);
    if (i >= 0) {
      cur.removeAt(i);
    } else {
      cur.removeWhere((e) => e.id == item.id && e.site == item.site);
    }
    await _save(cur);
  }

  static VodItem _copy(
    VodItem e, {
    String? id,
    String? name,
    String? pic,
    String? remarks,
    String? typeName,
    String? configSource,
  }) {
    return VodItem(
      id: id ?? e.id,
      name: name ?? e.name,
      pic: pic ?? e.pic,
      remarks: remarks ?? e.remarks,
      typeName: typeName ?? e.typeName,
      site: e.site,
      action: e.action,
      vodTag: e.vodTag,
      cate: e.cate,
      folder: e.folder,
      flag: e.flag,
      configSource: configSource ?? e.configSource,
      positionMs: e.positionMs,
      durationMs: e.durationMs,
    );
  }

  static Future<void> _save(List<VodItem> items) async {
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
                if (e.vodTag.trim().isNotEmpty) 'vod_tag': e.vodTag,
                if (e.cate.trim().isNotEmpty) 'cate': e.cate,
                if (e.action.trim().isNotEmpty) 'action': e.action,
                if (e.flag.trim().isNotEmpty) 'vod_flag': e.flag,
                if (e.configSource.trim().isNotEmpty) 'config_source': e.configSource,
                if (e.folder) 'is_folder': true,
              })
          .toList()),
    );
  }

  /// 同步协议 Keep JSON（site$$$id）。
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
            'type': 0,
            'cid': 0,
            'siteName': e.site,
          },
    ];
  }
}
