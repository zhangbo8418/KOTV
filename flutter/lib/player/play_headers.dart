/// 播放请求头规范化（全播放器共用）。
///
/// User-Agent 优先级：
/// 1. 请求头已有 User-Agent / ua
/// 2. 设置项 `ua`（非空）
/// 3. Android 上 [kotvSetPlatformPlayUa] 写入的系统 UA
/// 4. [kotvDefaultPlayUA]
library;

import 'hls_js_support.dart';

/// 桌面，以及 Android 尚未取到系统信息时的缺省值。
const kotvDefaultPlayUA =
    'com.bobo.kotv/0.1.0 (Linux;Android 13) ExoPlayerLib/1.4.1';

/// 设置里快捷填入用（输入 `c` / `o`）。
const kotvChromePlayUA =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36';

const kotvOkHttpPlayUA = 'okhttp/5.4.0';

String _settingsUa = '';
String _platformPlayUa = '';

/// 用设置里的 `ua` 刷新缓存（开播前 / 设置变更后调用）。
void kotvApplyPlayUaSetting(String? raw) {
  _settingsUa = (raw ?? '').trim();
}

/// Android 启动时写入 `Util.getUserAgent` 的结果（包名、versionName、系统版本）。
void kotvSetPlatformPlayUa(String? raw) {
  _platformPlayUa = (raw ?? '').trim();
}

/// 当前生效的缺省 UA。设置优先，其次 Android 系统 UA，否则 [kotvDefaultPlayUA]。
String kotvEffectivePlayUa() {
  if (_settingsUa.isNotEmpty) return _settingsUa;
  if (_platformPlayUa.isNotEmpty) return _platformPlayUa;
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

/// Exo，以及会用 hls.js 拉流的网页播放器，可以自己带请求头。
/// Safari 原生 HLS、西瓜和全能播放器不走这条。
bool kotvPlaybackSendsHeaders({
  required String playerVal,
  required String mediaUrl,
  bool? hlsJsSupported,
}) {
  if (playerVal == 'innie#exo') return true;
  final hls = hlsJsSupported ?? kotvWebHlsJsSupported();
  if (!hls) return false;
  switch (playerVal) {
    case 'innie#html':
      return true;
    case 'innie#art':
      final path = mediaUrl.split('?').first.toLowerCase();
      return path.contains('.m3u8');
    default:
      return false;
  }
}

/// 播放器能否自己在每次请求上带请求头。只有这时才打开 [directUrl]。
bool kotvCanOpenDirect(String url) {
  final u = url.trim();
  if (u.isEmpty) return false;
  final uri = Uri.tryParse(u);
  if (uri == null) return false;
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;
  final host = uri.host.toLowerCase();
  if (host.isEmpty || host == 'localhost' || host == '127.0.0.1' || host == '::1') {
    return false;
  }
  if (kotvIsLocalProxyUrl(u) || u.contains('/proxy/rolling_m3u8')) return false;
  return true;
}

/// 选定最终 open 地址。
/// [sendHeaders] 且 [directUrl] 可直连时，打开站点地址并带上请求头。
/// 其它情况打开引擎返回的播放地址。
({String url, Map<String, String>? headers}) kotvResolvePlayOpenTarget({
  required String playUrl,
  required Map<String, String> headers,
  required bool magnet,
  String directUrl = '',
  bool sendHeaders = false,
}) {
  if (magnet) {
    return (url: playUrl, headers: headers.isEmpty ? null : headers);
  }
  if (sendHeaders && kotvCanOpenDirect(directUrl)) {
    return (url: directUrl, headers: headers.isEmpty ? null : headers);
  }
  final cached = playUrl.contains('/proxy/cached_m3u8');
  if (cached) {
    return (url: playUrl, headers: null);
  }
  final proxied = kotvIsLocalProxyUrl(playUrl);
  return (
    url: playUrl,
    headers: proxied || headers.isEmpty ? null : headers,
  );
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
