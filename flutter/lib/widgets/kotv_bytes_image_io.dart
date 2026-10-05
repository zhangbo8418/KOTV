import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// 桌面和 iOS 用自己的客户端拉海报。
/// Image.network 用 headers.add，会在 Dart 默认 User-Agent 后再加一条。
/// 豆瓣看到两条 User-Agent 就回 403；这里用 set 覆盖。
ImageProvider kotvBytesImageProvider(String url, Map<String, String> headers) {
  return KotvHttpImage(url, headers: headers.isEmpty ? null : Map<String, String>.from(headers));
}

class KotvHttpImage extends ImageProvider<KotvHttpImage> {
  const KotvHttpImage(this.url, {this.headers, this.scale = 1.0});

  final String url;
  final Map<String, String>? headers;
  final double scale;

  static final HttpClient _client = HttpClient()..autoUncompress = true;

  @override
  Future<KotvHttpImage> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<KotvHttpImage>(this);
  }

  @override
  ImageStreamCompleter loadImage(KotvHttpImage key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _fetch(key, (buffer) => decode(buffer)),
      scale: key.scale,
    );
  }

  @override
  ImageStreamCompleter loadBuffer(KotvHttpImage key, DecoderBufferCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _fetch(key, (buffer) => decode(buffer)),
      scale: key.scale,
    );
  }

  static Future<ui.Codec> _fetch(
    KotvHttpImage key,
    Future<ui.Codec> Function(ui.ImmutableBuffer buffer) decode,
  ) async {
    try {
      final uri = Uri.parse(key.url);
      final req = await _client.getUrl(uri);
      key.headers?.forEach((name, value) {
        req.headers.set(name, value);
      });
      final res = await req.close();
      if (res.statusCode != HttpStatus.ok) {
        await res.drain<void>();
        throw NetworkImageLoadException(statusCode: res.statusCode, uri: uri);
      }
      final bytes = await consolidateHttpClientResponseBytes(res);
      if (bytes.isEmpty) {
        throw StateError('empty image: $uri');
      }
      return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
    } catch (e) {
      scheduleMicrotask(() {
        PaintingBinding.instance.imageCache.evict(key);
      });
      rethrow;
    }
  }

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType) return false;
    return other is KotvHttpImage &&
        other.url == url &&
        other.scale == scale &&
        mapEquals(other.headers, headers);
  }

  @override
  int get hashCode {
    final entries = headers?.entries ?? const <MapEntry<String, String>>[];
    return Object.hash(url, scale, Object.hashAllUnordered(entries));
  }
}
