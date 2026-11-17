/// DVD / Blu-ray / ISO：走自带 libmpv（dvdnav + libbluray，或 `force-iso`）。
///
/// 开播请用 [openPlan] / [openPlanAny]；详情与播控只认这一处。
class KotvDiscPlay {
  KotvDiscPlay._();

  /// 是否像碟片 / ISO（含 `http(s)` 直链 `.iso`、`file:`、本机路径、VIDEO_TS、BDMV）。
  static bool looksLike(String raw) => openPlan(raw) != null;

  /// 任一候选像碟片 / ISO。
  static bool looksLikeAny(Iterable<String> candidates) {
    for (final c in candidates) {
      if (looksLike(c)) return true;
    }
    return false;
  }

  /// 开播计划；非碟片返回 null。
  ///
  /// - `.iso`：保留原 URL，附加 `force-iso=yes`（mpv 按 ISO9660/UDF 打开）
  /// - `VIDEO_TS` 目录：`dvd://` + `dvd-device`
  /// - `BDMV` 目录：`bd://` + `bluray-device`
  static ({String url, Map<String, String> props, bool forceMpv})? openPlan(String raw) {
    final u = raw.trim();
    if (u.isEmpty) return null;
    final low = u.toLowerCase();
    if (low.startsWith('dvd://') || low.startsWith('bd://') || low.startsWith('bluray://')) {
      return (url: u, props: const {}, forceMpv: true);
    }

    final path = _pathOf(u);
    final upper = path.replaceAll('\\', '/').toUpperCase();
    if (upper.contains('/BDMV') || upper.endsWith('BDMV')) {
      final device = _discRoot(path, 'BDMV');
      return (
        url: 'bd://',
        props: {'bluray-device': device},
        forceMpv: true,
      );
    }
    if (upper.contains('/VIDEO_TS') || upper.endsWith('VIDEO_TS')) {
      final device = _discRoot(path, 'VIDEO_TS');
      return (
        url: 'dvd://',
        props: {'dvd-device': device},
        forceMpv: true,
      );
    }
    if (_endsWithIso(path) || _endsWithIso(u)) {
      return (
        url: u,
        props: const {'force-iso': 'yes'},
        forceMpv: true,
      );
    }
    return null;
  }

  /// 按候选顺序取第一个有效开播计划。
  static ({String url, Map<String, String> props, bool forceMpv})? openPlanAny(
    Iterable<String> candidates,
  ) {
    for (final c in candidates) {
      final plan = openPlan(c);
      if (plan != null) return plan;
    }
    return null;
  }

  static bool _endsWithIso(String s) {
    final t = s.trim().toLowerCase();
    if (t.endsWith('.iso')) return true;
    try {
      final p = Uri.parse(t).path.toLowerCase();
      return p.endsWith('.iso');
    } catch (_) {
      return false;
    }
  }

  static String _pathOf(String u) {
    final t = u.trim();
    if (t.toLowerCase().startsWith('file:')) {
      try {
        final uri = Uri.parse(t);
        final p = uri.toFilePath();
        if (p.isNotEmpty) return p;
      } catch (_) {}
      return t.replaceFirst(RegExp(r'^file://', caseSensitive: false), '');
    }
    if (t.contains('://')) {
      try {
        final uri = Uri.parse(t);
        if (uri.path.isNotEmpty) return uri.path;
      } catch (_) {}
    }
    return t;
  }

  static String _discRoot(String path, String marker) {
    final norm = path.replaceAll('\\', '/');
    final idx = norm.toUpperCase().lastIndexOf('/$marker');
    if (idx > 0) return norm.substring(0, idx);
    if (norm.toUpperCase().endsWith(marker)) {
      final slash = norm.lastIndexOf('/');
      if (slash > 0) return norm.substring(0, slash);
    }
    return path;
  }
}
