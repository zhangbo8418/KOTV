import 'dart:convert';

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
