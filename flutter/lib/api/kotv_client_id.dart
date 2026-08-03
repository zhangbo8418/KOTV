import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

const _prefsKey = 'kotv_client_id';

String? _cached;

/// 本机 Flutter 实例的稳定 clientId（多前端连同一引擎时用于 UI 路由）。
Future<String> kotvClientId() async {
  if (_cached != null && _cached!.isNotEmpty) return _cached!;
  final prefs = await SharedPreferences.getInstance();
  var id = prefs.getString(_prefsKey)?.trim() ?? '';
  if (id.isEmpty) {
    id = _newId();
    await prefs.setString(_prefsKey, id);
  }
  _cached = id;
  return id;
}

String _newId() {
  final r = Random.secure();
  final bytes = List<int>.generate(16, (_) => r.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
