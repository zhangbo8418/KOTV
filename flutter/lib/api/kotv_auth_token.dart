import 'kotv_client_store.dart';

String? _tokenCached;
String? _userCached;

Future<String> kotvAuthToken() async {
  if (_tokenCached != null) return _tokenCached!;
  _tokenCached = await KotvClientStore.authToken();
  return _tokenCached!;
}

Future<void> kotvSetAuthToken(String token) async {
  _tokenCached = token.trim();
  await KotvClientStore.setAuthToken(_tokenCached!);
}

/// 登录会话里的 userId（Web 本站登录 / PC·安卓远端登录后写入）；本机免登录为空。
Future<String> kotvSessionUserId() async {
  if (_userCached != null) return _userCached!;
  _userCached = await KotvClientStore.authUserId();
  return _userCached!;
}

Future<void> kotvSetSessionUserId(String id) async {
  _userCached = id.trim();
  await KotvClientStore.setAuthUserId(_userCached!);
}

/// 清登录态：token 与会话 userId 一起清。
Future<void> kotvClearAuthToken() async {
  _tokenCached = '';
  _userCached = '';
  await KotvClientStore.clearAuth();
}
