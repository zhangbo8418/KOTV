import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 本机设置：内存同步可读，落盘 SharedPreferences；引擎写入由调用方另推。
class KotvLocalPrefs {
  static const _key = 'kotv_local_settings_v1';
  static final Map<String, String> _mem = {};
  static bool _diskLoaded = false;

  static bool get isEmpty => _mem.isEmpty;

  static String get(String key, [String def = '']) {
    final v = _mem[key];
    if (v == null || v.isEmpty) return def;
    return v;
  }

  static Map<String, dynamic> asMap() => {for (final e in _mem.entries) e.key: e.value};

  /// 内存优先；空则暖盘。不请求引擎。
  static Future<Map<String, dynamic>> snapshot() async {
    if (_mem.isNotEmpty) return asMap();
    await loadFromDisk();
    return asMap();
  }

  static Future<void> put(String key, String value) async {
    _mem[key] = value;
    await _persist();
  }

  static Future<void> putMany(Map<String, String> kv) async {
    if (kv.isEmpty) return;
    _mem.addAll(kv);
    await _persist();
  }

  /// 用引擎返回的 settings 灌入本机（启动 / 进页 / 设置页拉取后）。
  static Future<void> hydrate(Map<String, dynamic> settings) async {
    if (settings.isEmpty) return;
    for (final e in settings.entries) {
      _mem['${e.key}'] = '${e.value ?? ''}';
    }
    await _persist();
  }

  static Future<void> loadFromDisk() async {
    if (_diskLoaded && _mem.isNotEmpty) return;
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_key);
    _diskLoaded = true;
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      for (final e in decoded.entries) {
        final k = '${e.key}';
        if (k.isEmpty) continue;
        // 磁盘只补空缺，避免盖住本会话已 put 的值。
        if (_mem.containsKey(k) && _mem[k]!.isNotEmpty) continue;
        _mem[k] = '${e.value ?? ''}';
      }
    } catch (_) {}
  }

  static Future<void> _persist() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_key, jsonEncode(_mem));
      _diskLoaded = true;
    } catch (_) {}
  }
}
