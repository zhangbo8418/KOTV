/// 播放请求头规范化（全播放器共用）。
///
/// User-Agent 优先级（与成熟播放端一致）：
/// 1. 请求头已有 User-Agent / ua
/// 2. 设置项 `ua`（非空）
/// 3. [kotvDefaultPlayUA]
library;

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
  return u.contains('/proxy/play') ||
      u.contains('/proxy/cached_m3u8') ||
      u.contains('/proxy/bt/') ||
      (u.contains('127.0.0.1:') && u.contains('/proxy/'));
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
