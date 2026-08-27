/// 播放请求头规范化（全播放器共用）。
///
/// User-Agent 优先级（与成熟播放端一致）：
/// 1. 请求头已有 User-Agent / ua
/// 2. 设置项 `ua`（非空）
/// 3. [kotvDefaultPlayUA]
library;

import 'dart:convert';

/// Media3 `Util.getUserAgent(applicationId)` 格式缺省值。
const kotvDefaultPlayUA =
    'com.bobo.kotv/0.1.0 (Linux;Android 13) ExoPlayerLib/1.4.1';

/// 设置里快捷填入用（输入 `c` / `o`）。
const kotvChromePlayUA =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36';

const kotvOkHttpPlayUA = 'okhttp/5.4.0';

String _settingsUa = '';

/// 用设置里的 `ua` 刷新缓存（开播前 / 设置变更后调用）。
void kotvApplyPlayUaSetting(String? raw) {
  _settingsUa = (raw ?? '').trim();
}

/// 当前生效的缺省 UA（设置优先，否则 [kotvDefaultPlayUA]）。
String kotvEffectivePlayUa() {
  if (_settingsUa.isNotEmpty) return _settingsUa;
  return kotvDefaultPlayUA;
}

bool kotvIsLocalProxyUrl(String url) {
  final u = url.toLowerCase();
  if (u.contains('/proxy/play') ||
      u.contains('/proxy/cached_m3u8') ||
      u.contains('/proxy/bt/')) {
    return true;
  }
  // spider 本地代理：改写到局域网 IP 后仍是 /proxy?...，不能再带 CDN 头。
  try {
    final uri = Uri.parse(url);
    final path = uri.path.endsWith('/') && uri.path.length > 1
        ? uri.path.substring(0, uri.path.length - 1)
        : uri.path;
    if (path == '/proxy') return true;
  } catch (_) {}
  return u.contains('127.0.0.1:') && u.contains('/proxy');
}

/// 展开网盘「/proxy?url=&header=」为直链+请求头（对齐后端 ExpandSpiderMediaProxy）。
/// m3u8 不展开。失败返回 null。
({String url, Map<String, String> headers})? kotvExpandSpiderMediaProxy(
  String raw, {
  Map<String, String>? existing,
}) {
  var s = raw.trim();
  if (s.isEmpty) return null;
  if (s.startsWith('proxy://')) {
    s = 'http://127.0.0.1/proxy?${s.substring('proxy://'.length)}';
  }
  final Uri uri;
  try {
    uri = Uri.parse(s);
  } catch (_) {
    return null;
  }
  final path = uri.path.endsWith('/') && uri.path.length > 1
      ? uri.path.substring(0, uri.path.length - 1)
      : uri.path;
  if (path != '/proxy') return null;
  final encUrl = uri.queryParameters['url']?.trim() ?? '';
  if (encUrl.isEmpty) return null;
  final decodedUrl = _decodeProxyB64(encUrl)?.trim() ?? '';
  if (decodedUrl.isEmpty) return null;
  final low = decodedUrl.toLowerCase();
  if (low.contains('.m3u8') || low.contains('mpegurl')) return null;
  if (!low.startsWith('http://') && !low.startsWith('https://')) return null;

  final out = <String, String>{};
  if (existing != null) {
    for (final e in existing.entries) {
      final k = e.key.trim();
      final v = e.value.trim();
      if (k.isNotEmpty && v.isNotEmpty) out[k] = v;
    }
  }
  final encHdr =
      (uri.queryParameters['header'] ?? uri.queryParameters['headers'] ?? '')
          .trim();
  if (encHdr.isNotEmpty) {
    final jsonStr = _decodeProxyB64(encHdr);
    if (jsonStr != null && jsonStr.isNotEmpty) {
      try {
        final parsed = jsonDecode(jsonStr);
        if (parsed is Map) {
          parsed.forEach((k, v) {
            final hk = '$k'.trim();
            final hv = '$v'.trim();
            if (hk.isNotEmpty && hv.isNotEmpty) out[hk] = hv;
          });
        }
      } catch (_) {}
    }
  }
  return (url: decodedUrl, headers: out);
}

/// 选定最终 open 地址：能带请求头的播放器优先直连 CDN（media / 展开 proxy）。
({String url, Map<String, String>? headers}) kotvResolvePlayOpenTarget({
  required String playUrl,
  required String mediaUrl,
  required Map<String, String> headers,
  required bool magnet,
  required bool preferDirectMedia,
}) {
  if (magnet) {
    return (url: playUrl, headers: headers.isEmpty ? null : headers);
  }
  final cached = playUrl.contains('/proxy/cached_m3u8');
  if (cached) {
    return (url: playUrl, headers: null);
  }

  if (preferDirectMedia) {
    final mediaDirect = mediaUrl.startsWith('http') &&
        !kotvIsLocalProxyUrl(mediaUrl) &&
        headers.isNotEmpty;
    if (mediaDirect) {
      return (url: mediaUrl, headers: headers);
    }
    final fromPlay = kotvExpandSpiderMediaProxy(playUrl, existing: headers);
    if (fromPlay != null) {
      return (url: fromPlay.url, headers: fromPlay.headers);
    }
    final fromMedia = kotvExpandSpiderMediaProxy(mediaUrl, existing: headers);
    if (fromMedia != null) {
      return (url: fromMedia.url, headers: fromMedia.headers);
    }
  }

  final proxied = kotvIsLocalProxyUrl(playUrl);
  return (
    url: playUrl,
    headers: proxied || headers.isEmpty ? null : headers,
  );
}

String? _decodeProxyB64(String s) {
  var t = s.trim();
  if (t.isEmpty) return null;
  try {
    t = Uri.decodeQueryComponent(t);
  } catch (_) {}
  try {
    var padded = t;
    final m = padded.length % 4;
    if (m != 0) padded = padded.padRight(padded.length + (4 - m), '=');
    return utf8.decode(base64Decode(padded));
  } catch (_) {
    try {
      return utf8.decode(base64Decode(t));
    } catch (_) {
      return null;
    }
  }
}

/// 规范化请求头；本地代理 URL 返回空（代理侧已带远端头）。
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
    out['User-Agent'] = kotvEffectivePlayUa();
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
