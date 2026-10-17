import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../api/kotv_engine_url.dart';
import '../player/kotv_traffic.dart';
import 'kotv_frame_image.dart';

export 'kotv_frame_image.dart';

/// 默认海报 UA（非 Android 直连时用）。
const kotvDefaultImageUa =
    'Mozilla/5.0 (Linux; Android 7.1.2; TV) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/99.0.4844.88 Safari/537.36';

/// 解析站源海报地址：支持 `url@Headers={...}` / `url@Referer=...`。
/// [defaultUa] 为 false 时不补 User-Agent。浏览器里多出来的请求头会让跨域图片失败。
({String url, Map<String, String> headers}) kotvParseImageUrl(
  String raw, {
  bool defaultUa = true,
}) {
  var s = raw.trim();
  final headers = <String, String>{};
  if (s.isEmpty) return (url: '', headers: headers);

  const mark = '@Headers=';
  final hi = s.indexOf(mark);
  if (hi > 0) {
    final base = s.substring(0, hi).trim();
    final rest = s.substring(hi + mark.length).trim();
    _mergeJsonHeaders(rest, headers);
    s = base;
  } else {
    final scheme = s.indexOf('://');
    final at = s.indexOf('@', scheme > 0 ? scheme + 3 : 0);
    if (scheme > 0 && at > scheme + 3) {
      final after = s.substring(at + 1);
      if (_looksLikePicDecorator(after)) {
        final parts = s.split('@');
        s = parts.first.trim();
        for (var i = 1; i < parts.length; i++) {
          final p = parts[i];
          final eq = p.indexOf('=');
          if (eq <= 0) continue;
          final key = p.substring(0, eq).trim();
          final val = p.substring(eq + 1).trim();
          if (key.isEmpty || val.isEmpty) continue;
          if (key.toLowerCase() == 'headers') {
            _mergeJsonHeaders(val, headers);
          } else {
            headers[_canonImageHeader(key)] = val;
          }
        }
      }
    }
  }

  if (defaultUa) {
    headers.putIfAbsent('User-Agent', () => kotvDefaultImageUa);
  }
  _ensureHotlinkReferer(s, headers);
  return (url: s, headers: headers);
}

String _joinEngine(String base, String pathAndQuery) {
  var b = base.trim();
  while (b.endsWith('/')) {
    b = b.substring(0, b.length - 1);
  }
  if (b.isEmpty) b = kotvDefaultLocalEngineBaseUrl;
  if (pathAndQuery.startsWith('/')) return '$b$pathAndQuery';
  return '$b/$pathAndQuery';
}

/// 海报最终请求：proxy/file/引擎相对路径改到当前引擎根，回环引擎路径改到客户端正在连的主机。
({String url, Map<String, String> headers}) kotvResolveImageRequest(String raw) {
  var s = raw.trim();
  final base = KotvTraffic.engineBaseUrl;
  final lower = s.toLowerCase();
  if (lower.startsWith('proxy://')) {
    s = _joinEngine(base, '/proxy?${s.substring('proxy://'.length)}');
  } else if (lower.startsWith('file://')) {
    var path = s.substring('file://'.length);
    while (path.startsWith('/')) {
      path = path.substring(1);
    }
    path = Uri.encodeComponent(path).replaceAll('%2F', '/');
    s = _joinEngine(base, '/file/$path');
  } else if (s.startsWith('/image/') || s.startsWith('/file/') || s.startsWith('/proxy')) {
    s = _joinEngine(base, s);
  }
  final parsed = kotvParseImageUrl(s, defaultUa: !kIsWeb);
  return (
    url: kotvRewriteEngineLocalUrl(parsed.url, base),
    headers: parsed.headers,
  );
}

/// 豆瓣等 CDN 防盗链：站源常省略 @Referer=，直连会 403。
void _ensureHotlinkReferer(String imageUrl, Map<String, String> headers) {
  if (headers.containsKey('Referer')) return;
  final host = Uri.tryParse(imageUrl)?.host.toLowerCase() ?? '';
  if (host.isEmpty) return;
  if (host.contains('doubanio.com') || host == 'douban.com' || host.endsWith('.douban.com')) {
    headers['Referer'] = 'https://movie.douban.com/';
  }
}

bool _looksLikePicDecorator(String after) {
  final low = after.toLowerCase();
  return low.startsWith('headers=') ||
      low.startsWith('referer=') ||
      low.startsWith('user-agent=') ||
      low.startsWith('origin=') ||
      low.startsWith('cookie=');
}

void _mergeJsonHeaders(String raw, Map<String, String> headers) {
  try {
    final obj = jsonDecode(raw);
    if (obj is! Map) return;
    obj.forEach((k, v) {
      if (k == null || v == null) return;
      final key = '$k'.trim();
      final val = '$v'.trim();
      if (key.isEmpty || val.isEmpty) return;
      headers[_canonImageHeader(key)] = val;
    });
  } catch (_) {}
}

String _canonImageHeader(String key) {
  switch (key.toLowerCase()) {
    case 'user-agent':
    case 'ua':
      return 'User-Agent';
    case 'referer':
    case 'referrer':
      return 'Referer';
    case 'origin':
      return 'Origin';
    case 'cookie':
      return 'Cookie';
    default:
      return key;
  }
}

Uint8List? kotvDecodeDataImage(String raw) {
  final s = raw.trim();
  if (!s.toLowerCase().startsWith('data:image/')) return null;
  if (s.length > 8 * 1024 * 1024) return null;
  final comma = s.indexOf(',');
  if (comma < 5) return null;
  final meta = s.substring(5, comma).toLowerCase();
  if (!meta.endsWith(';base64')) return null;
  final mime = meta.split(';').first;
  if (!RegExp(r'^image/[a-z0-9.+-]+$').hasMatch(mime)) return null;
  try {
    final bytes = base64Decode(s.substring(comma + 1).replaceAll(RegExp(r'\s'), ''));
    if (bytes.isEmpty) return null;
    return bytes;
  } catch (_) {
    return null;
  }
}

/// 通用网络图（壁纸、台标、详情封面等；分类列表海报用 [KotvPosterNetImage]）。
/// 默认走客户端拉图（含 `@Headers=`）；勿默认开 Android Glide PlatformView——
/// 同屏壳壁纸/多图换帧时原生层创建销毁会拖闪背景。
/// 仅个别确需 Glide 的场景再显式 [allowPlatformView]: true。
class KotvNetworkImage extends StatelessWidget {
  const KotvNetworkImage(
    this.pic, {
    super.key,
    this.fit = BoxFit.cover,
    this.errorBuilder,
    this.alignment = Alignment.center,
    this.filterQuality = FilterQuality.low,
    this.cacheWidth,
    this.cacheHeight,
    this.allowPlatformView = false,
    this.gaplessPlayback = true,
  });

  final String pic;
  final BoxFit fit;
  final ImageErrorWidgetBuilder? errorBuilder;
  final Alignment alignment;
  final FilterQuality filterQuality;
  final int? cacheWidth;
  final int? cacheHeight;
  /// 默认 false。true 时 Android 用 Glide PlatformView（少用，易拖闪壳壁纸）。
  final bool allowPlatformView;
  /// 为 false 时换地址先清掉上一张，避免列表复用同一格时留着旧图。
  final bool gaplessPlayback;

  @override
  Widget build(BuildContext context) {
    final raw = pic.trim();
    if (raw.isEmpty) {
      if (errorBuilder != null) {
        return errorBuilder!(context, StateError('empty pic'), StackTrace.empty);
      }
      return const SizedBox.shrink();
    }

    final useGlide = allowPlatformView && !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    if (useGlide) {
      final fitParam = fit == BoxFit.contain ? 'contain' : 'cover';
      // 海报 PlatformView 不参与遥控器焦点，避免焦点陷进原生 ImageView。
      return ExcludeFocus(
        child: AndroidView(
          viewType: 'kotv/glide_image',
          key: ValueKey('glide|$raw|$fitParam'),
          creationParams: <String, dynamic>{
            'url': raw,
            'fit': fitParam,
          },
          creationParamsCodec: const StandardMessageCodec(),
          gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
          hitTestBehavior: PlatformViewHitTestBehavior.transparent,
        ),
      );
    }

    final bytes = kotvDecodeDataImage(raw);
    if (bytes != null) {
      return KotvFrameImage(
        bytes: bytes,
        fit: fit,
        alignment: alignment,
        filterQuality: filterQuality,
        targetWidth: cacheWidth,
        targetHeight: cacheHeight,
        gaplessPlayback: gaplessPlayback,
        errorBuilder: errorBuilder,
      );
    }

    final parsed = kotvResolveImageRequest(raw);
    if (parsed.url.isEmpty ||
        !(parsed.url.startsWith('http://') || parsed.url.startsWith('https://'))) {
      if (errorBuilder != null) {
        return errorBuilder!(context, StateError('empty pic'), StackTrace.empty);
      }
      return const SizedBox.shrink();
    }
    return KotvFrameImage(
      url: parsed.url,
      headers: parsed.headers,
      fit: fit,
      alignment: alignment,
      filterQuality: filterQuality,
      targetWidth: cacheWidth,
      targetHeight: cacheHeight,
      gaplessPlayback: gaplessPlayback,
      errorBuilder: errorBuilder,
    );
  }
}
