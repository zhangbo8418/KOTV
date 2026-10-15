import 'kotv_client_store.dart';

String? _tokenCached;

Future<String> kotvAuthToken() async {
  if (_tokenCached != null) return _tokenCached!;
  _tokenCached = await KotvClientStore.authToken();
  return _tokenCached!;
}

Future<void> kotvSetAuthToken(String token) async {
  _tokenCached = token.trim();
  await KotvClientStore.setAuthToken(_tokenCached!);
}

/// 清登录态。
Future<void> kotvClearAuthToken() async {
  _tokenCached = '';
  await KotvClientStore.clearAuth();
}
