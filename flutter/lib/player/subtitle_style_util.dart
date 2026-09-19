/// 字幕颜色 / 透明度工具。
///
/// [opacityPct] 乘在**原色 alpha**上，而不是整段替换：
/// `#00000000`×100% 仍透明；`#80000000`×50% → `#40000000`。
String kotvHexWithOpacity(String hex, double opacityPct) {
  final raw = hex.trim();
  if (raw.isEmpty) return raw;
  final h = raw.startsWith('#') ? raw.substring(1) : raw;
  int rgb;
  int origA = 0xFF;
  if (h.length == 8) {
    origA = int.tryParse(h.substring(0, 2), radix: 16) ?? 0xFF;
    rgb = int.tryParse(h.substring(2), radix: 16) ?? 0xFFFFFF;
  } else if (h.length == 6) {
    rgb = int.tryParse(h, radix: 16) ?? 0xFFFFFF;
  } else if (h.length == 3) {
    final r = h[0], g = h[1], b = h[2];
    rgb = int.tryParse('$r$r$g$g$b$b', radix: 16) ?? 0xFFFFFF;
  } else {
    return raw.startsWith('#') ? raw : '#$raw';
  }
  final a = ((origA * opacityPct.clamp(0, 100) / 100.0).round()).clamp(0, 255);
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

/// default / sans / serif / mono。
String kotvNormalizeSubtitleFont(String? raw) {
  final f = (raw ?? '').trim().toLowerCase();
  return switch (f) {
    'sans' || 'sans-serif' || 'serif' || 'mono' || 'monospace' => f == 'sans-serif'
        ? 'sans'
        : (f == 'monospace' ? 'mono' : f),
    _ => 'default',
  };
}

/// 0–100；默认 50。
double kotvSubtitleShadowStrength(String? raw, {double def = 50}) {
  return (double.tryParse('${raw ?? ''}') ?? def).clamp(0, 100);
}

/// none / outline / shadow。
String kotvNormalizeDanmakuStroke(String? raw) {
  final s = (raw ?? '').trim().toLowerCase();
  return switch (s) {
    'none' || 'outline' => s,
    _ => 'shadow',
  };
}

/// original / white / yellow。
String kotvNormalizeDanmakuColorMode(String? raw) {
  final s = (raw ?? '').trim().toLowerCase();
  return switch (s) {
    'white' || 'yellow' => s,
    _ => 'original',
  };
}
