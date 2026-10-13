import 'kotv_api.dart';

/// 进程内缓存：仅吸收引擎 `/api/v1/settings` 响应，不落盘。
class KotvSettingsCache {
  static final Map<String, dynamic> _settings = {};

  static Map<String, dynamic> peek() => Map<String, dynamic>.from(_settings);

  static String get(String key, [String def = '']) {
    final v = '${_settings[key] ?? ''}'.trim();
    return v.isEmpty ? def : v;
  }

  static void clear() => _settings.clear();

  /// 用引擎返回的 settings 整表替换（避免换引擎后残留旧键）。
  static void replace(Map? settings) {
    _settings.clear();
    if (settings == null || settings.isEmpty) return;
    for (final e in settings.entries) {
      _settings['${e.key}'] = e.value;
    }
  }

  /// 拉引擎；非 [force] 且已有缓存则直接返回。
  static Future<Map<String, dynamic>> fetch(KotvApi api, {bool force = false}) async {
    if (!force && _settings.isNotEmpty) return peek();
    final st = await api.getSettings();
    replace(st['settings'] as Map?);
    return peek();
  }

  /// 写引擎并刷新缓存；返回完整 API 响应（含 pairCode 等）。
  static Future<Map<String, dynamic>> set(KotvApi api, String key, String value) async {
    final data = await api.setSetting(key, value);
    replace(data['settings'] as Map?);
    _settings[key] = value;
    return data;
  }

  static Future<Map<String, dynamic>> setMany(KotvApi api, Map<String, String> kv) async {
    final data = await api.setSettings(kv);
    replace(data['settings'] as Map?);
    _settings.addAll(kv);
    return data;
  }
}
