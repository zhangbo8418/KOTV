/// 引擎 baseUrl 是否指向本机（127.0.0.1 / localhost / ::1）。
/// 本机连接不鉴权、不带账号；仅非本机地址才用远端登录。
bool kotvIsLocalEngineBaseUrl(String baseUrl) {
  final raw = baseUrl.trim();
  if (raw.isEmpty) return true;
  try {
    final host = Uri.parse(raw.contains('://') ? raw : 'http://$raw').host.toLowerCase();
    return host.isEmpty ||
        host == '127.0.0.1' ||
        host == 'localhost' ||
        host == '::1' ||
        host == '[::1]';
  } catch (_) {
    final u = raw.toLowerCase();
    return u.contains('127.0.0.1') || u.contains('localhost');
  }
}

/// 规范化引擎地址：支持 http / https；无协议时默认 http（局域网 IP 常用）。
/// 空串表示恢复默认本机。非法协议原样尽量保留以便报错可见。
String kotvNormalizeEngineBaseUrl(String raw) {
  var v = raw.trim();
  if (v.isEmpty) return '';
  if (!v.contains('://')) {
    v = 'http://$v';
  } else {
    final scheme = v.split('://').first.toLowerCase();
    if (scheme == 'http' || scheme == 'https') {
      v = '$scheme://${v.substring(scheme.length + 3)}';
    }
  }
  // 去掉末尾多余 /，保留 https://x 这类最短合法形态
  while (v.endsWith('/')) {
    final bare = v.substring(0, v.length - 1);
    if (bare.endsWith(':/') || !bare.contains('://')) break;
    final rest = bare.split('://').skip(1).join('://');
    if (rest.isEmpty) break;
    v = bare;
  }
  return v;
}

/// 远端引擎返回的 `http://127.0.0.1:port/proxy/...` 对本机不可达；
/// 改写为当前 [engineBaseUrl] 的 host，便于手机拉流。
String kotvRewriteEngineLocalUrl(String mediaUrl, String engineBaseUrl) {
  final media = mediaUrl.trim();
  final baseRaw = engineBaseUrl.trim();
  if (media.isEmpty || baseRaw.isEmpty) return media;
  if (kotvIsLocalEngineBaseUrl(baseRaw)) return media;
  late final Uri m;
  late final Uri b;
  try {
    m = Uri.parse(media);
    b = Uri.parse(baseRaw.contains('://') ? baseRaw : 'http://$baseRaw');
  } catch (_) {
    return media;
  }
  if (b.host.isEmpty) return media;
  final host = m.host.toLowerCase();
  if (host != '127.0.0.1' && host != 'localhost' && host != '::1') {
    return media;
  }
  return Uri(
    scheme: b.scheme.isEmpty ? 'http' : b.scheme,
    userInfo: m.userInfo.isEmpty ? null : m.userInfo,
    host: b.host,
    port: b.hasPort ? b.port : null,
    path: m.path,
    query: m.hasQuery ? m.query : null,
    fragment: m.hasFragment ? m.fragment : null,
  ).toString();
}
