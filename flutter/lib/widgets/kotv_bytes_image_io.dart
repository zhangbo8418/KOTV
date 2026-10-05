import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// 非浏览器用自己的客户端拉图。
/// Image.network 用 headers.add，会在 Dart 默认 User-Agent 后再加一条。
/// 豆瓣看到两条 User-Agent 就回 403；这里用 set 覆盖。
ImageProvider kotvBytesImageProvider(String url, Map<String, String> headers, {bool singleFrame = false}) {
  return KotvHttpImage(
    url,
    headers: headers.isEmpty ? null : Map<String, String>.from(headers),
    singleFrame: singleFrame,
  );
}

/// 内存图只出第一帧。台标里的动图不再逐帧回写缓存。
ImageProvider kotvStillMemoryImage(Uint8List bytes) {
  return _KotvStillMemoryImage(bytes);
}

class KotvHttpImage extends ImageProvider<KotvHttpImage> {
  const KotvHttpImage(this.url, {this.headers, this.scale = 1.0, this.singleFrame = false});

  final String url;
  final Map<String, String>? headers;
  final double scale;
  final bool singleFrame;

  static final HttpClient _client = HttpClient()..autoUncompress = true;

  @override
  Future<KotvHttpImage> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<KotvHttpImage>(this);
  }

  @override
  ImageStreamCompleter loadImage(KotvHttpImage key, ImageDecoderCallback decode) {
    if (key.singleFrame) {
      return OneFrameImageStreamCompleter(_firstFrame(key, (buffer) => decode(buffer)));
    }
    return MultiFrameImageStreamCompleter(
      codec: _fetch(key, (buffer) => decode(buffer)),
      scale: key.scale,
    );
  }

  @override
  ImageStreamCompleter loadBuffer(KotvHttpImage key, DecoderBufferCallback decode) {
    if (key.singleFrame) {
      return OneFrameImageStreamCompleter(_firstFrame(key, (buffer) => decode(buffer)));
    }
    return MultiFrameImageStreamCompleter(
      codec: _fetch(key, (buffer) => decode(buffer)),
      scale: key.scale,
    );
  }

  static Future<ImageInfo> _firstFrame(
    KotvHttpImage key,
    Future<ui.Codec> Function(ui.ImmutableBuffer buffer) decode,
  ) async {
    final codec = await _fetch(key, decode);
    final frame = await codec.getNextFrame();
    codec.dispose();
    return ImageInfo(image: frame.image, scale: key.scale);
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
        other.singleFrame == singleFrame &&
        mapEquals(other.headers, headers);
  }

  @override
  int get hashCode {
    final entries = headers?.entries ?? const <MapEntry<String, String>>[];
    return Object.hash(url, scale, singleFrame, Object.hashAllUnordered(entries));
  }
}

class _KotvStillMemoryImage extends ImageProvider<_KotvStillMemoryImage> {
  const _KotvStillMemoryImage(this.bytes);

  final Uint8List bytes;

  @override
  Future<_KotvStillMemoryImage> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<_KotvStillMemoryImage>(this);
  }

  @override
  ImageStreamCompleter loadImage(_KotvStillMemoryImage key, ImageDecoderCallback decode) {
    return OneFrameImageStreamCompleter(_decode(key, (buffer) => decode(buffer)));
  }

  @override
  ImageStreamCompleter loadBuffer(_KotvStillMemoryImage key, DecoderBufferCallback decode) {
    return OneFrameImageStreamCompleter(_decode(key, (buffer) => decode(buffer)));
  }

  static Future<ImageInfo> _decode(
    _KotvStillMemoryImage key,
    Future<ui.Codec> Function(ui.ImmutableBuffer buffer) decode,
  ) async {
    final codec = await decode(await ui.ImmutableBuffer.fromUint8List(key.bytes));
    final frame = await codec.getNextFrame();
    codec.dispose();
    return ImageInfo(image: frame.image, scale: 1);
  }

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType) return false;
    return other is _KotvStillMemoryImage && other.bytes == bytes;
  }

  @override
  int get hashCode => bytes.hashCode;
}
