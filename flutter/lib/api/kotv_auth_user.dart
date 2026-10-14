import 'package:shared_preferences/shared_preferences.dart';

const _prefsKey = 'kotv_auth_user_id';

String? _cached;

/// 当前登录用户 id（远端租户）；本机未登录为空。
Future<String> kotvAuthUserId() async {
  if (_cached != null) return _cached!;
  final p = await SharedPreferences.getInstance();
  _cached = p.getString(_prefsKey)?.trim() ?? '';
  return _cached!;
}

Future<void> kotvSetAuthUserId(String id) async {
  _cached = id.trim();
  final p = await SharedPreferences.getInstance();
  if (_cached!.isEmpty) {
    await p.remove(_prefsKey);
  } else {
    await p.setString(_prefsKey, _cached!);
  }
}

Future<void> kotvClearAuthUserId() => kotvSetAuthUserId('');
