import 'package:shared_preferences/shared_preferences.dart';

const _prefsKey = 'kotv_auth_token';

String? _cached;

Future<String> kotvAuthToken() async {
  if (_cached != null) return _cached!;
  final p = await SharedPreferences.getInstance();
  _cached = p.getString(_prefsKey)?.trim() ?? '';
  return _cached!;
}

Future<void> kotvSetAuthToken(String token) async {
  _cached = token.trim();
  final p = await SharedPreferences.getInstance();
  if (_cached!.isEmpty) {
    await p.remove(_prefsKey);
  } else {
    await p.setString(_prefsKey, _cached!);
  }
}

Future<void> kotvClearAuthToken() => kotvSetAuthToken('');
