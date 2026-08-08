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

  static Future<bool> isKept(String id, String site) async {
    final list = await LocalCollect.list();
    return list.any((e) => e.id == id && e.site == site);
  }

  static Future<bool> toggle(VodItem item) async {
    final cur = await list();
    final i = cur.indexWhere((e) => e.id == item.id && e.site == item.site);
    if (i >= 0) {
      cur.removeAt(i);
      await _save(cur);
      return false;
    }
    cur.insert(0, item);
    await _save(cur.take(200).toList());
    return true;
  }

  static Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_key);
  }

  static Future<void> remove(VodItem item) async {
    final cur = await list();
    cur.removeWhere((e) => e.id == item.id && e.site == item.site);
    await _save(cur);
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
              })
          .toList()),
    );
  }
}
