import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

/// 默认海报 UA（非 Android 直连时用）。
const kotvDefaultImageUa =
    'Mozilla/5.0 (Linux; Android 7.1.2; TV) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/99.0.4844.88 Safari/537.36';

/// 解析站源海报地址：支持 CatVod `url@Headers={...}` / `url@Referer=...`（对齐 TV ImgUtil）。
({String url, Map<String, String> headers}) kotvParseImageUrl(String raw) {
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

  headers.putIfAbsent('User-Agent', () => kotvDefaultImageUa);
  return (url: s, headers: headers);
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

/// 统一网络海报。
/// Android：对齐 TV [ImgUtil] —— PlatformView + Glide 解析 `@Headers=`。
/// 其它平台：Image.network + 解析后的 headers。
class KotvNetworkImage extends StatelessWidget {
  const KotvNetworkImage(
    this.pic, {
    super.key,
    this.fit = BoxFit.cover,
    this.errorBuilder,
    this.alignment = Alignment.center,
  });

  final String pic;
  final BoxFit fit;
  final ImageErrorWidgetBuilder? errorBuilder;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    final raw = pic.trim();
    if (raw.isEmpty) {
      if (errorBuilder != null) {
        return errorBuilder!(context, StateError('empty pic'), StackTrace.empty);
      }
      return const SizedBox.shrink();
    }

    final useGlide = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
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

    final parsed = kotvParseImageUrl(raw);
    if (parsed.url.isEmpty ||
        !(parsed.url.startsWith('http://') || parsed.url.startsWith('https://'))) {
      if (errorBuilder != null) {
        return errorBuilder!(context, StateError('empty pic'), StackTrace.empty);
      }
      return const SizedBox.shrink();
    }
    return Image.network(
      parsed.url,
      fit: fit,
      alignment: alignment,
      headers: parsed.headers,
      errorBuilder: errorBuilder,
      filterQuality: FilterQuality.low,
      gaplessPlayback: true,
    );
  }
}
