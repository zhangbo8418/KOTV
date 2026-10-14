import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../api/kotv_api.dart';

/// 把本机 SP 历史/收藏回写引擎 DB，供对端 Export / 配对拉取。
class SyncMirrorPush {
  static Timer? _histTimer;
  static Timer? _keepTimer;
  static List<Map<String, dynamic>>? _pendingHist;
  static List<Map<String, dynamic>>? _pendingKeep;

  static void scheduleHistory(List<Map<String, dynamic>> targets) {
    _pendingHist = targets;
    _histTimer?.cancel();
    _histTimer = Timer(const Duration(milliseconds: 600), () {
      final body = _pendingHist;
      _pendingHist = null;
      if (body == null) return;
      unawaited(_push(history: body));
    });
  }

  static void scheduleKeep(List<Map<String, dynamic>> targets) {
    _pendingKeep = targets;
    _keepTimer?.cancel();
    _keepTimer = Timer(const Duration(milliseconds: 600), () {
      final body = _pendingKeep;
      _pendingKeep = null;
      if (body == null) return;
      unawaited(_push(keep: body));
    });
  }

  static Future<void> _push({
    List<Map<String, dynamic>>? history,
    List<Map<String, dynamic>>? keep,
  }) async {
    try {
      final p = await SharedPreferences.getInstance();
      final base = (p.getString('engine_base_url') ?? '').trim();
      final api = KotvApi(baseUrl: base.isEmpty ? 'http://127.0.0.1:9978' : base);
      await api.tools('mirrorSync', {
        if (history != null) 'history': jsonEncode(history),
        if (keep != null) 'keep': jsonEncode(keep),
      }).timeout(const Duration(seconds: 4));
    } catch (_) {}
  }
}
