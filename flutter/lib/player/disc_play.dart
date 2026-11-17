/// DVD / Blu-ray / ISO：走自带 libmpv（dvdnav + libbluray，或 `force-iso`）。
///
/// 开播请用 [openPlan] / [openPlanAny]；详情与播控只认这一处。
class KotvDiscPlay {
  KotvDiscPlay._();

  /// 每次 open 先复位，避免会话复用后 `force-iso` 粘滞。
  static const Map<String, String> clearedOpenProps = {'force-iso': 'no'};

  /// 合并开播 props：始终带 [clearedOpenProps]，再叠计划里的项。
  static Map<String, String> openPropsFor(Map<String, String>? planProps) {
    if (planProps == null || planProps.isEmpty) {
      return Map<String, String>.from(clearedOpenProps);
    }
    return {...clearedOpenProps, ...planProps};
  }

  /// 是否像碟片 / ISO（含 `http(s)` 直链 `.iso`、`file:`、本机路径、本地 VIDEO_TS、BDMV）。
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
  /// - `.iso`（含远程 URL）：保留原 URL，附加 `force-iso=yes`
  /// - 本地 `VIDEO_TS` 目录：`dvd://` + `dvd-device`
  /// - 本地 `BDMV` 目录：`bd://` + `bluray-device`
  static ({String url, Map<String, String> props, bool forceMpv})? openPlan(String raw) {
    final u = raw.trim();
    if (u.isEmpty) return null;
    final low = u.toLowerCase();
    if (low.startsWith('dvd://') || low.startsWith('bd://') || low.startsWith('bluray://')) {
      return (url: u, props: const {}, forceMpv: true);
    }

    if (_endsWithIso(_pathOf(u)) || _endsWithIso(u)) {
      return (
        url: u,
        props: const {'force-iso': 'yes'},
        forceMpv: true,
      );
    }

    // 目录碟需要本机可读 device；远程 path 里偶然含 VIDEO_TS/BDMV 不得改写。
    if (!_isLocalDiscPath(u)) return null;

    final path = _pathOf(u);
    final upper = path.replaceAll('\\', '/').toUpperCase();
    if (_pathHasDiscMarker(upper, 'BDMV')) {
      final device = _discRoot(path, 'BDMV');
      return (
        url: 'bd://',
        props: {'bluray-device': device},
        forceMpv: true,
      );
    }
    if (_pathHasDiscMarker(upper, 'VIDEO_TS')) {
      final device = _discRoot(path, 'VIDEO_TS');
      return (
        url: 'dvd://',
        props: {'dvd-device': device},
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

  /// 本机 / file: / content:；带其它 scheme 的不当目录碟。
  static bool _isLocalDiscPath(String u) {
    final t = u.trim();
    if (t.isEmpty) return false;
    final low = t.toLowerCase();
    if (low.startsWith('file:') || low.startsWith('content:')) return true;
    if (low.contains('://')) return false;
    return t.startsWith('/') || RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(t);
  }

  /// 路径段边界匹配，避免 `VIDEO_TS_BACKUP` / `BDMV_COPY` 误中。
  static bool _pathHasDiscMarker(String upperNormPath, String marker) {
    final m = marker.toUpperCase();
    if (upperNormPath == m || upperNormPath.endsWith('/$m')) return true;
    if (upperNormPath.contains('/$m/')) return true;
    return false;
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
