import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../api/kotv_api.dart';
import 'local_collect.dart';
import 'remote_bridge.dart';

/// 同步接收后：引擎 settings 里的 pending → 本机 SP。
class SyncImportApply {
  static Future<void>? _inflight;

  static Future<void> pull() {
    return _inflight ??= _do().whenComplete(() {
      _inflight = null;
    });
  }

  static Future<void> _do() async {
    try {
      final p = await SharedPreferences.getInstance();
      final base = (p.getString('engine_base_url') ?? '').trim();
      final api = KotvApi(baseUrl: base.isEmpty ? 'http://127.0.0.1:9978' : base);
      final data = await api.tools('consumeSyncImport').timeout(const Duration(seconds: 2));
      final hist = '${data['history'] ?? ''}'.trim();
      final keep = '${data['keep'] ?? ''}'.trim();
      if (hist.isNotEmpty) {
        await LocalHistory.replaceAll(LocalHistory.fromSyncTargets(hist));
      }
      if (keep.isNotEmpty) {
        await LocalCollect.replaceAll(LocalCollect.fromSyncTargets(keep));
      }
    } catch (_) {}
  }
}

/// 解析同步/备份里的 key（site$$$id 或 id@site）。
void parseSyncVodKey(String key, void Function(String site, String id) out) {
  key = key.trim();
  if (key.isEmpty) {
    out('', '');
    return;
  }
  if (key.contains(r'$$$')) {
    final i = key.indexOf(r'$$$');
    out(key.substring(0, i), key.substring(i + 3));
    return;
  }
  if (key.contains('@')) {
    final i = key.lastIndexOf('@');
    out(key.substring(i + 1), key.substring(0, i));
    return;
  }
  out('', key);
}

int syncInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse('$v') ?? 0;
}

List<Map<String, dynamic>> decodeSyncList(String raw) {
  if (raw.trim().isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    return [
      for (final e in decoded)
        if (e is Map) Map<String, dynamic>.from(e),
    ];
  } catch (_) {
    return const [];
  }
}
