import '../api/kotv_api.dart';
import '../api/kotv_client_id.dart';
import '../player/kotv_traffic.dart';

/// Web：不拉起本机进程，只探测 / 会话离开。
class EngineLauncher {
  EngineLauncher();

  bool _shuttingDown = false;
  String baseUrl = 'http://127.0.0.1:9978';
  KotvApi? _api;

  KotvApi client() {
    _api ??= KotvApi(baseUrl: baseUrl);
    _api!.baseUrl = baseUrl;
    KotvTraffic.engineBaseUrl = baseUrl;
    return _api!;
  }

  void applyBaseUrl(String url) {
    // Web 只能用当前页面同源后端，忽略外部改址。
    final origin = Uri.base.origin;
    baseUrl = (origin.isNotEmpty && origin != 'null') ? origin : 'http://127.0.0.1:9978';
    _api?.baseUrl = baseUrl;
    KotvTraffic.engineBaseUrl = baseUrl;
  }

  Future<bool> ensureReady({Duration timeout = const Duration(seconds: 30)}) async {
    await kotvClientId();
    // 每次就绪探测前对齐页面 origin（避免仍停在默认 127.0.0.1）
    applyBaseUrl('');
    if (_shuttingDown) return false;
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await _ping(baseUrl)) return true;
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    return await _ping(baseUrl);
  }

  Future<bool> recoverIfNeeded({bool forceRestart = false}) async {
    if (_shuttingDown) return false;
    return _ping(baseUrl);
  }

  Future<bool> onAppResumed() async {
    if (_shuttingDown) return false;
    return _ping(baseUrl);
  }

  Future<Map<String, dynamic>?> _health(String base) async {
    try {
      final h = await KotvApi(baseUrl: base).health().timeout(const Duration(seconds: 2));
      return Map<String, dynamic>.from(h);
    } catch (_) {
      return null;
    }
  }

  Future<bool> _ping(String base) async {
    final h = await _health(base);
    return h != null && h['ok'] == true;
  }

  Future<void> shutdown() async {
    _shuttingDown = true;
    try {
      await KotvApi(baseUrl: baseUrl).sessionLeave();
    } catch (_) {}
  }

  void shutdownSync() {
    _shuttingDown = true;
    // Web 无法同步 HTTP；异步尽力离开会话。
    // ignore: discarded_futures
    KotvApi(baseUrl: baseUrl).sessionLeave().catchError((_) => <String, dynamic>{});
  }

  void dispose() {
    if (!_shuttingDown) {
      // ignore: discarded_futures
      shutdown();
    }
  }
}
