/// 没有图片时，行首显示名称的第一个字。
String kotvNameInitial(String name) {
  final s = name.trim();
  if (s.isEmpty) return '?';
  return String.fromCharCode(s.runes.first);
}
