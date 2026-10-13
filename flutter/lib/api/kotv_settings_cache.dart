import 'kotv_api.dart';

/// 进程内缓存：只吸收引擎 `/api/v1/settings` 的响应，不落盘、不另立真相源。
class KotvSettingsCache {
  static final Map<String, dynamic> _settings = {};

  static bool get isEmpty => _settings.isEmpty;

  static Map<String, dynamic> peek() => Map<String, dynamic>.from(_settings);

  static String get(String key, [String def = '']) {
    final v = '${_settings[key] ?? ''}'.trim();
    return v.isEmpty ? def : v;
  }

  static void absorb(Map? settings) {
    if (settings == null || settings.isEmpty) return;
    for (final e in settings.entries) {
      _settings['${e.key}'] = e.value;
    }
  }

  /// 拉引擎；[force] 或缓存空时请求。
  static Future<Map<String, dynamic>> fetch(KotvApi api, {bool force = false}) async {
    if (!force && _settings.isNotEmpty) return peek();
    final st = await api.getSettings();
    absorb(st['settings'] as Map?);
    return peek();
  }

  static Future<Map<String, dynamic>> set(KotvApi api, String key, String value) async {
    final data = await api.setSetting(key, value);
    absorb(data['settings'] as Map?);
    _settings[key] = value;
    return peek();
  }

  static Future<Map<String, dynamic>> setMany(KotvApi api, Map<String, String> kv) async {
    final data = await api.setSettings(kv);
    absorb(data['settings'] as Map?);
    _settings.addAll(kv);
    return peek();
  }
}
