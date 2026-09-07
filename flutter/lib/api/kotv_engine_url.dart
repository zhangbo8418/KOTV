import 'package:flutter/foundation.dart' show kIsWeb;

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

/// 将引擎回环/内网代理地址改写为客户端配置的引擎根。
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
  if (b.host.isEmpty) return media;
  final host = m.host.toLowerCase();
  if (host.isEmpty) return media;
  final baseHost = b.host.toLowerCase();
  if (host == baseHost) {
    if (b.scheme.isNotEmpty && m.scheme != b.scheme) {
      return m.replace(scheme: b.scheme, host: b.host, port: b.hasPort ? b.port : null).toString();
    }
    return media;
  }
  final rewrite = _isLoopbackHost(host) || _isPrivateOrLinkLocalIPv4(host);
  if (!rewrite) return media;
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
