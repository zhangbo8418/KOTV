/// 字幕颜色 / 透明度工具。
String kotvHexWithOpacity(String hex, double opacityPct) {
  final raw = hex.trim();
  if (raw.isEmpty) return raw;
  final h = raw.startsWith('#') ? raw.substring(1) : raw;
  int rgb;
  if (h.length == 8) {
    rgb = int.tryParse(h.substring(2), radix: 16) ?? 0xFFFFFF;
  } else if (h.length == 6) {
    rgb = int.tryParse(h, radix: 16) ?? 0xFFFFFF;
  } else if (h.length == 3) {
    final r = h[0], g = h[1], b = h[2];
    rgb = int.tryParse('$r$r$g$g$b$b', radix: 16) ?? 0xFFFFFF;
  } else {
    return raw.startsWith('#') ? raw : '#$raw';
  }
  final a = ((opacityPct.clamp(0, 100) / 100.0) * 255).round().clamp(0, 255);
  final out = ((a << 24) | (rgb & 0xFFFFFF)).toRadixString(16).padLeft(8, '0').toUpperCase();
  return '#$out';
}

String kotvNormalizeSubtitleEdgeType(String? raw) {
  final e = (raw ?? '').trim().toLowerCase();
  return switch (e) {
    'none' || 'shadow' || 'raised' || 'depressed' => e,
    _ => 'outline',
  };
}
