/// 站点或条目声明 `list` 时，用横向行而不是海报格。
bool kotvListStyle({String site = '', String page = '', Iterable<String> items = const []}) {
  bool isList(String s) => s.trim().toLowerCase() == 'list';
  if (isList(site) || isList(page)) return true;
  for (final it in items) {
    if (isList(it)) return true;
  }
  return false;
}

/// 没有图片时，行首显示名称的第一个字。
String kotvNameInitial(String name) {
  final s = name.trim();
  if (s.isEmpty) return '?';
  return String.fromCharCode(s.runes.first);
}
