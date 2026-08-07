/// 引擎 baseUrl 是否指向本机（127.0.0.1 / localhost / ::1）。
/// 本机连接不鉴权、不带账号；仅非本机地址才用远端登录。
bool kotvIsLocalEngineBaseUrl(String baseUrl) {
  final raw = baseUrl.trim();
  if (raw.isEmpty) return true;
  try {
    final host = Uri.parse(raw).host.toLowerCase();
    return host == '127.0.0.1' ||
        host == 'localhost' ||
        host == '::1' ||
        host == '[::1]';
  } catch (_) {
    final u = raw.toLowerCase();
    return u.contains('127.0.0.1') || u.contains('localhost');
  }
}
