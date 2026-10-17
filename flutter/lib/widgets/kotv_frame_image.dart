import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// 自己持有一个 codec。一帧的 jpg、png、webp 停在第一帧；
/// 多帧的 gif、动态 webp 按该帧时长换图，同时只留一张。
/// 不把每一帧放进图片缓存。
class KotvFrameImage extends StatefulWidget {
  const KotvFrameImage({
    super.key,
    this.bytes,
    this.url,
    this.headers = const {},
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.filterQuality = FilterQuality.low,
    this.targetWidth,
    this.targetHeight,
    this.gaplessPlayback = true,
    this.errorBuilder,
  });

  final Uint8List? bytes;
  final String? url;
  final Map<String, String> headers;
  final BoxFit fit;
  final Alignment alignment;
  final FilterQuality filterQuality;
  final int? targetWidth;
  final int? targetHeight;
  final bool gaplessPlayback;
  final ImageErrorWidgetBuilder? errorBuilder;

  @override
  State<KotvFrameImage> createState() => _KotvFrameImageState();
}

class _KotvFrameImageState extends State<KotvFrameImage> {
  static final http.Client _client = http.Client();

  ui.Image? _owned;
  ui.Codec? _codec;
  Timer? _timer;
  int _gen = 0;
  int _shown = 0;
  Object? _error;
  StackTrace? _stack;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(covariant KotvFrameImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (listEquals(oldWidget.bytes, widget.bytes) &&
        oldWidget.url == widget.url &&
        oldWidget.targetWidth == widget.targetWidth &&
        oldWidget.targetHeight == widget.targetHeight &&
        mapEquals(oldWidget.headers, widget.headers)) {
      return;
    }
    if (!widget.gaplessPlayback) {
      final prev = _owned;
      _owned = null;
      prev?.dispose();
    }
    _start();
  }

  @override
  void dispose() {
    _gen++;
    _timer?.cancel();
    _codec?.dispose();
    _codec = null;
    _owned?.dispose();
    _owned = null;
    super.dispose();
  }

  void _start() {
    _timer?.cancel();
    _timer = null;
    final gen = ++_gen;
    _shown = 0;
    _error = null;
    _stack = null;
    unawaited(_load(gen));
  }

  Future<void> _load(int gen) async {
    ui.Codec? codec;
    try {
      final bytes = widget.bytes ?? await _fetch(widget.url ?? '', widget.headers);
      if (!mounted || gen != _gen) return;
      final tw = widget.targetWidth;
      final th = widget.targetHeight;
      codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: tw != null && tw > 0 ? tw : null,
        targetHeight: th != null && th > 0 ? th : null,
      );
      if (!mounted || gen != _gen) {
        codec.dispose();
        return;
      }
      _codec?.dispose();
      _codec = codec;
      codec = null;
      await _showNext(gen);
    } catch (e, st) {
      codec?.dispose();
      if (!mounted || gen != _gen) return;
      setState(() {
        _error = e;
        _stack = st;
      });
    }
  }

  Future<void> _showNext(int gen) async {
    final codec = _codec;
    if (codec == null || !mounted || gen != _gen) return;
    ui.FrameInfo? frame;
    try {
      frame = await codec.getNextFrame();
      if (!mounted || gen != _gen) {
        frame.image.dispose();
        return;
      }
      final prev = _owned;
      final next = frame.image;
      _owned = next;
      setState(() {});
      if (prev != null && !identical(prev, next)) prev.dispose();
      _shown++;
      if (codec.frameCount <= 1) {
        _releaseCodec();
        return;
      }
      final cycles = _shown ~/ codec.frameCount;
      if (codec.repetitionCount != -1 && cycles > codec.repetitionCount) {
        _releaseCodec();
        return;
      }
      final delay = frame.duration <= Duration.zero
          ? const Duration(milliseconds: 100)
          : frame.duration;
      _timer = Timer(delay, () {
        if (!mounted || gen != _gen) return;
        unawaited(_showNext(gen));
      });
    } catch (e, st) {
      final failed = frame?.image;
      if (failed != null && !identical(failed, _owned)) failed.dispose();
      if (!mounted || gen != _gen) return;
      setState(() {
        _error = e;
        _stack = st;
      });
    }
  }

  void _releaseCodec() {
    _codec?.dispose();
    _codec = null;
  }

  static Future<Uint8List> _fetch(String url, Map<String, String> headers) async {
    final uri = Uri.parse(url);
    final resp = await _client.get(uri, headers: headers);
    if (resp.statusCode != 200) {
      throw http.ClientException('HTTP ${resp.statusCode}', uri);
    }
    if (resp.bodyBytes.isEmpty) {
      throw StateError('empty image: $uri');
    }
    return resp.bodyBytes;
  }

  @override
  Widget build(BuildContext context) {
    final err = _error;
    final owned = _owned;
    if (err != null && owned == null) {
      final builder = widget.errorBuilder;
      if (builder != null) return builder(context, err, _stack);
      return const SizedBox.shrink();
    }
    // RawImage 会在换图和卸树时 dispose 它拿到的那份句柄，这里只把副本交出去。
    return RawImage(
      image: owned?.clone(),
      fit: widget.fit,
      alignment: widget.alignment,
      filterQuality: widget.filterQuality,
    );
  }
}
