import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// 解出第一帧后立刻释放 codec，避免动图逐帧回写图片缓存。
Future<ImageInfo> kotvDecodeFirstFrame(
  Future<ui.Codec> codec, {
  double scale = 1,
}) async {
  final c = await codec;
  try {
    final frame = await c.getNextFrame();
    return ImageInfo(image: frame.image, scale: scale);
  } finally {
    c.dispose();
  }
}

/// 内存中的图片只出第一帧。
ImageProvider kotvStillMemoryImage(Uint8List bytes) {
  return _KotvStillMemoryImage(bytes);
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
    return OneFrameImageStreamCompleter(_decode(key, decode));
  }

  @override
  ImageStreamCompleter loadBuffer(_KotvStillMemoryImage key, DecoderBufferCallback decode) {
    return OneFrameImageStreamCompleter(_decode(key, decode));
  }

  static Future<ImageInfo> _decode(
    _KotvStillMemoryImage key,
    Future<ui.Codec> Function(ui.ImmutableBuffer buffer) decode,
  ) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(key.bytes);
    return kotvDecodeFirstFrame(decode(buffer));
  }

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType) return false;
    return other is _KotvStillMemoryImage && other.bytes == bytes;
  }

  @override
  int get hashCode => bytes.hashCode;
}
