import 'dart:convert';

/// 热榜和联想都从 `data` 里取标题：有 `title` 用 `title`，否则用 `name`。
List<String> parseSuggestTitles(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map) return const [];
    final data = decoded['data'];
    if (data is! List) return const [];
    final out = <String>[];
    final seen = <String>{};
    for (final item in data) {
      if (item is! Map) continue;
      var title = '${item['title'] ?? ''}'.trim();
      if (title.isEmpty) title = '${item['name'] ?? ''}'.trim();
      if (title.isEmpty || !seen.add(title)) continue;
      out.add(title);
    }
    return out;
  } catch (_) {
    return const [];
  }
}
