import 'package:flutter/foundation.dart' show kIsWeb;

/// 本机引擎默认端口（与 Go `localproxy.DefaultPort` 一致）。
const kotvDefaultEnginePort = 9978;

/// 引擎因 [kotvDefaultEnginePort] 被别的程序占着而退出时的退出码；引擎（Go）与安卓引擎服务用同一个数。
const kotvEnginePortInUseExit = 98;

/// 客户端版本（与 `update.CurrentVersion`、pubspec `version` 同步）。
/// 引擎尚未返回 version 时也用它显示；打包后应以引擎 API 为准。
const kotvClientVersion = '0.3.6';

/// 前后端接口协议号（与 Go `server.ProtocolVersion` 一致）。远端后端不同则不能连接。
const kotvProtocolVersion = 1;

/// 安卓 Spider 侧车端口（与 Go `localproxy.DefaultBridgePort` 一致；≠ 引擎端口）。
const kotvDefaultSpiderBridgePort = 9979;

/// 本机引擎默认地址（无 client.json / 无有效远端地址时使用）。
const kotvDefaultLocalEngineBaseUrl = 'http://127.0.0.1:$kotvDefaultEnginePort';

/// 本机 Spider 侧车根地址。
const kotvDefaultSpiderBridgeBaseUrl = 'http://127.0.0.1:$kotvDefaultSpiderBridgePort';

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

/// Web 无配置地址时用页面 origin；否则本机引擎默认根。
String kotvFallbackEngineBaseUrl() {
  if (kIsWeb) {
    final origin = Uri.base.origin;
    if (origin.isNotEmpty && origin != 'null') return origin;
  }
  return kotvDefaultLocalEngineBaseUrl;
}

/// 运行时有效引擎地址：无地址 / 空 host / 无效 → Web 用页面 origin，否则本机 9978；http 无端口补 9978。
String kotvEffectiveEngineBaseUrl(String raw) {
  final n = kotvNormalizeEngineBaseUrl(raw);
  if (n.isEmpty) return kotvFallbackEngineBaseUrl();
  late final Uri u;
  try {
    u = Uri.parse(n);
  } catch (_) {
    return kotvFallbackEngineBaseUrl();
  }
  if (u.host.isEmpty) return kotvFallbackEngineBaseUrl();
  final scheme = u.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') {
    return kotvFallbackEngineBaseUrl();
  }
  if (!u.hasPort && scheme == 'http') {
    return u.replace(port: kotvDefaultEnginePort).toString();
  }
  return n;
}

/// 写入 client.json 的引擎地址：本机/无效存空串；远端 http 无端口时带上 9978。
String kotvStoreEngineBaseUrl(String raw) {
  final n = kotvNormalizeEngineBaseUrl(raw);
  if (n.isEmpty || kotvIsLocalEngineBaseUrl(n)) return '';
  final effective = kotvEffectiveEngineBaseUrl(n);
  if (kotvIsLocalEngineBaseUrl(effective)) return '';
  return effective;
}

/// 远端后端的媒体钥匙（登录后由 /auth/me 下发；本机为空）。
/// 播放器、图片加载带不了登录头，客户端自己拼出的媒体地址要带上它：/k/<钥匙>/proxy/…
String kotvEngineMediaKey = '';

/// 去掉地址路径里的媒体钥匙前缀 /k/<钥匙>。
String kotvStripMediaKey(String path) {
  if (!path.startsWith('/k/')) return path;
  final i = path.indexOf('/', 3);
  return i < 0 ? path : path.substring(i);
}

/// 媒体地址（与引擎 `playproxy.IsMediaPath` 一致）：凭媒体钥匙可以只读访问。
bool kotvIsEngineMediaPath(String path) {
  var p = path;
  if (p.length > 1 && p.endsWith('/')) p = p.substring(0, p.length - 1);
  if (p == '/node/msg' || p == '/msg') return false;
  return p == '/proxy' ||
      p.startsWith('/proxy/') ||
      p.startsWith('/file/') ||
      p.startsWith('/image/') ||
      p == '/tvbus' ||
      p.startsWith('/node/');
}

/// 本进程 HTTP 服务提供的路径（与引擎 `playproxy.IsEngineRoute` 一致）。其它回环路径是 jar 自己的监听。
bool kotvIsEngineServedPath(String path) {
  var p = path;
  if (p.length > 1 && p.endsWith('/')) {
    p = p.substring(0, p.length - 1);
  }
  return kotvIsEngineMediaPath(p) ||
      p == '/file' ||
      p == '/image' ||
      p == '/parse' ||
      p.startsWith('/parse/') ||
      p == '/cache' ||
      p.startsWith('/cache/') ||
      p == '/upload' ||
      p.startsWith('/upload/') ||
      p == '/newFolder' ||
      p == '/delFolder' ||
      p == '/delFile' ||
      p == '/health' ||
      p == '/media' ||
      p == '/device' ||
      p == '/action' ||
      p == '/ui' ||
      p == '/library' ||
      p == '/java' ||
      p.startsWith('/api/');
}

bool _isLoopbackHost(String host) {
  final h = host.toLowerCase();
  return h == '127.0.0.1' || h == 'localhost' || h == '::1' || h == '[::1]';
}

bool _isPrivateOrLinkLocalIPv4(String host) {
  final parts = host.split('.');
  if (parts.length != 4) return false;
  final nums = <int>[];
  for (final p in parts) {
    final n = int.tryParse(p);
    if (n == null || n < 0 || n > 255) return false;
    nums.add(n);
  }
  final a = nums[0], b = nums[1];
  if (a == 10) return true;
  if (a == 172 && b >= 16 && b <= 31) return true;
  if (a == 192 && b == 168) return true;
  if (a == 169 && b == 254) return true;
  return false;
}

/// 将引擎回环/内网地址改写为客户端连接的引擎根；远端媒体地址补上媒体钥匙。
/// - 原生：用 [engineBaseUrl]（远端或域名映射）
/// - Web：优先用当前页面 [Uri.base.origin]
String kotvRewriteEngineLocalUrl(String mediaUrl, String engineBaseUrl) {
  final media = mediaUrl.trim();
  if (media.isEmpty) return media;
  var baseRaw = engineBaseUrl.trim();
  if (kIsWeb) {
    final origin = Uri.base.origin;
    if (origin.isNotEmpty && origin != 'null') {
      baseRaw = origin;
    }
  }
  if (baseRaw.isEmpty) return media;
  // Web 即使用户误把引擎指到 127，仍按页面 origin 改写
  if (!kIsWeb && kotvIsLocalEngineBaseUrl(baseRaw)) return media;
  late final Uri m;
  late final Uri b;
  try {
    m = Uri.parse(media);
    b = Uri.parse(baseRaw.contains('://') ? baseRaw : 'http://$baseRaw');
  } catch (_) {
    return media;
  }
  final host = m.host.toLowerCase();
  if (b.host.isEmpty || host.isEmpty || !kotvIsEngineServedPath(m.path)) return media;
  final sameHost = host == b.host.toLowerCase();
  if (!sameHost && !_isLoopbackHost(host) && !_isPrivateOrLinkLocalIPv4(host)) return media;
  final key = kotvEngineMediaKey;
  final path = key.isNotEmpty && kotvIsEngineMediaPath(m.path) ? '/k/$key${m.path}' : m.path;
  final scheme = b.scheme.isEmpty ? m.scheme : b.scheme;
  final port = b.hasPort ? b.port : null;
  if (sameHost && path == m.path && scheme == m.scheme && port == (m.hasPort ? m.port : null)) {
    return media;
  }
  return Uri(
    scheme: scheme,
    userInfo: m.userInfo.isEmpty ? null : m.userInfo,
    host: b.host,
    port: port,
    path: path,
    query: m.hasQuery ? m.query : null,
    fragment: m.hasFragment ? m.fragment : null,
  ).toString();
}
