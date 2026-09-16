/// 本地 DVD / Blu-ray / ISO：走自带 libmpv（dvdnav + libbluray）。
///
/// 说明：`IsoSessionManager` stub 只满足 webhtv `register_iso_protocol` JNI 链接，
/// **不是**碟片播放入口。实际播用 mpv 的 `dvd://` / `bd://` + device 属性。
class KotvDiscPlay {
  KotvDiscPlay._();

  /// 是否像碟片路径（本地 ISO / VIDEO_TS / BDMV）。
  static bool looksLike(String raw) {
    final u = raw.trim();
    if (u.isEmpty) return false;
    final low = u.toLowerCase();
    if (low.startsWith('dvd://') || low.startsWith('bd://') || low.startsWith('bluray://')) {
      return true;
    }
    if (low.contains('://') && !low.startsWith('file:')) return false;
    final path = _pathOf(u);
    if (path.toLowerCase().endsWith('.iso')) return true;
    if (path.toUpperCase().contains('/VIDEO_TS') || path.toUpperCase().endsWith('VIDEO_TS')) {
      return true;
    }
    if (path.toUpperCase().contains('/BDMV') || path.toUpperCase().endsWith('BDMV')) {
      return true;
    }
    return false;
  }

  /// 改写为 mpv 可播 URL + 附加属性；[forceMpv] 恒 true。
  static ({String url, Map<String, String> props, bool forceMpv}) rewrite(String raw) {
    final u = raw.trim();
    final low = u.toLowerCase();
    if (low.startsWith('dvd://') || low.startsWith('bd://') || low.startsWith('bluray://')) {
      return (url: u, props: const {}, forceMpv: true);
    }
    final path = _pathOf(u);
    final upper = path.toUpperCase();
    if (upper.contains('/BDMV') || upper.endsWith('BDMV')) {
      final device = _discRoot(path, 'BDMV');
      return (
        url: 'bd://',
        props: {'bluray-device': device},
        forceMpv: true,
      );
    }
    if (upper.contains('/VIDEO_TS') || upper.endsWith('VIDEO_TS') || path.toLowerCase().endsWith('.iso')) {
      final device = path.toLowerCase().endsWith('.iso') ? path : _discRoot(path, 'VIDEO_TS');
      return (
        url: 'dvd://',
        props: {'dvd-device': device},
        forceMpv: true,
      );
    }
    return (url: u, props: const {}, forceMpv: true);
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
