/// 播放请求头规范化（对齐 TV UrlUtil.fixHeader / PlaySpec.checkUa）。
library;

const kotvDefaultPlayUA =
    'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

bool kotvIsLocalProxyUrl(String url) {
  final u = url.toLowerCase();
  return u.contains('/proxy/play') ||
      u.contains('/proxy/cached_m3u8') ||
      u.contains('/proxy/bt/') ||
      (u.contains('127.0.0.1:') && u.contains('/proxy/'));
}

/// 规范化请求头；[forLocalProxy]=true 时返回空（代理已注入远端头）。
Map<String, String> kotvNormalizePlayHeaders(
  Map<String, String>? headers, {
  required String url,
  bool addDefaultUa = true,
}) {
  if (kotvIsLocalProxyUrl(url)) return const {};
  final out = <String, String>{};
  if (headers != null) {
    for (final e in headers.entries) {
      var k = e.key.trim();
      var v = e.value.trim();
      if (k.isEmpty || v.isEmpty) continue;
      if (v.contains(r'$') && (v.contains('#') || k.toLowerCase() == 'header')) {
        for (final part in v.split('#')) {
          final i = part.indexOf(r'$');
          if (i <= 0) continue;
          final hk = _canonicalHeader(part.substring(0, i).trim());
          final hv = part.substring(i + 1).trim();
          if (hk.isNotEmpty && hv.isNotEmpty) out[hk] = hv;
        }
        continue;
      }
      out[_canonicalHeader(k)] = v;
    }
  }
  if (addDefaultUa && !out.keys.any((k) => k.toLowerCase() == 'user-agent')) {
    out['User-Agent'] = kotvDefaultPlayUA;
  }
  return out;
}

String _canonicalHeader(String k) {
  switch (k.toLowerCase()) {
    case 'user-agent':
    case 'ua':
      return 'User-Agent';
    case 'referer':
    case 'referrer':
      return 'Referer';
    case 'cookie':
      return 'Cookie';
    case 'origin':
      return 'Origin';
    case 'host':
      return 'Host';
    default:
      return k;
  }
}

/// ijkplayer format.headers：每行 `Key: Value`，以 `\r\n` 结尾。
String kotvHeadersToIjkFormat(Map<String, String> headers) {
  if (headers.isEmpty) return '';
  final buf = StringBuffer();
  for (final e in headers.entries) {
    buf.write('${e.key}: ${e.value}\r\n');
  }
  return buf.toString();
}
