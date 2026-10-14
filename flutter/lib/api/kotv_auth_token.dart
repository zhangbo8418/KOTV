import 'package:shared_preferences/shared_preferences.dart';

const _tokenKey = 'kotv_auth_token';
const _userKey = 'kotv_auth_user_id';

String? _tokenCached;
String? _userCached;

Future<String> kotvAuthToken() async {
  if (_tokenCached != null) return _tokenCached!;
  final p = await SharedPreferences.getInstance();
  _tokenCached = p.getString(_tokenKey)?.trim() ?? '';
  return _tokenCached!;
}

Future<void> kotvSetAuthToken(String token) async {
  _tokenCached = token.trim();
  final p = await SharedPreferences.getInstance();
  if (_tokenCached!.isEmpty) {
    await p.remove(_tokenKey);
  } else {
    await p.setString(_tokenKey, _tokenCached!);
  }
}

/// 登录会话里的 userId（Web 本站登录 / PC·安卓远端登录后写入）；本机免登录为空。
/// 只供历史/收藏分桶，不是二次鉴权。
Future<String> kotvSessionUserId() async {
  if (_userCached != null) return _userCached!;
  final p = await SharedPreferences.getInstance();
  _userCached = p.getString(_userKey)?.trim() ?? '';
  return _userCached!;
}

Future<void> kotvSetSessionUserId(String id) async {
  _userCached = id.trim();
  final p = await SharedPreferences.getInstance();
  if (_userCached!.isEmpty) {
    await p.remove(_userKey);
  } else {
    await p.setString(_userKey, _userCached!);
  }
}

/// 清登录态：token 与会话 userId 一起清。
Future<void> kotvClearAuthToken() async {
  await kotvSetAuthToken('');
  await kotvSetSessionUserId('');
}
