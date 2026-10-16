import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'kotv_network_image.dart';

/// 压缩字节 LRU：滚回同 URL 时免再下；解码尺寸由调用方固定桶决定。
final LinkedHashMap<String, Uint8List> _kotvPosterByteCache = LinkedHashMap<String, Uint8List>();
const int _kotvPosterByteCacheMax = 96;

void _kotvPosterByteCachePut(String key, Uint8List bytes) {
  _kotvPosterByteCache.remove(key);
  _kotvPosterByteCache[key] = bytes;
  while (_kotvPosterByteCache.length > _kotvPosterByteCacheMax) {
    _kotvPosterByteCache.remove(_kotvPosterByteCache.keys.first);
  }
}

Uint8List? _kotvPosterByteCacheGet(String key) {
  final hit = _kotvPosterByteCache.remove(key);
  if (hit == null) return null;
  _kotvPosterByteCache[key] = hit;
  return hit;
}

/// 列表海报：State 自管 HttpClient，[dispose] 时 abort（回收即停在途）。
class KotvPosterNetImage extends StatefulWidget {
  const KotvPosterNetImage(
    this.pic, {
    super.key,
    this.fit = BoxFit.cover,
    this.errorBuilder,
    this.designWidth = 214,
    this.designHeight = 286,
  });

  final String pic;
  final BoxFit fit;
  final ImageErrorWidgetBuilder? errorBuilder;
  /// 与网格 childAspectRatio 214/286 一致，解码键稳定。
  final double designWidth;
  final double designHeight;

  @override
  State<KotvPosterNetImage> createState() => _KotvPosterNetImageState();
}

class _KotvPosterNetImageState extends State<KotvPosterNetImage> {
  static final HttpClient _client = HttpClient()..autoUncompress = true;

  ui.Image? _image;
  Object? _error;
  int _gen = 0;
  HttpClientRequest? _req;
  StreamSubscription<List<int>>? _sub;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(KotvPosterNetImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pic != widget.pic ||
        oldWidget.designWidth != widget.designWidth ||
        oldWidget.designHeight != widget.designHeight) {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _abort();
    _image?.dispose();
    _image = null;
    super.dispose();
  }

  void _abort() {
    try {
      _req?.abort();
    } catch (_) {}
    _req = null;
    unawaited(_sub?.cancel() ?? Future<void>.value());
    _sub = null;
  }

  Future<void> _load() async {
    final gen = ++_gen;
    _abort();
    final prev = _image;
    _image = null;
    prev?.dispose();
    _error = null;
    if (mounted) setState(() {});

    final raw = widget.pic.trim();
    if (raw.isEmpty) {
      _error = StateError('empty pic');
      if (mounted && gen == _gen) setState(() {});
      return;
    }

    final dpr = View.of(context).devicePixelRatio;
    final tw = (widget.designWidth * dpr).round().clamp(1, 720);
    final th = (widget.designHeight * dpr).round().clamp(1, 960);

    final dataBytes = kotvDecodeDataImage(raw);
    if (dataBytes != null) {
      await _decodeAndShow(dataBytes, tw, th, gen);
      return;
    }

    final parsed = kotvResolveImageRequest(raw);
    if (parsed.url.isEmpty ||
        !(parsed.url.startsWith('http://') || parsed.url.startsWith('https://'))) {
      _error = StateError('bad pic');
      if (mounted && gen == _gen) setState(() {});
      return;
    }

    final cacheKey = parsed.url;
    final cached = _kotvPosterByteCacheGet(cacheKey);
    if (cached != null) {
      await _decodeAndShow(cached, tw, th, gen);
      return;
    }

    try {
      final uri = Uri.parse(parsed.url);
      final req = await _client.getUrl(uri);
      if (gen != _gen || !mounted) {
        try {
          req.abort();
        } catch (_) {}
        return;
      }
      _req = req;
      parsed.headers.forEach(req.headers.set);
      final res = await req.close();
      if (gen != _gen || !mounted) {
        await res.drain<void>();
        return;
      }
      if (res.statusCode != HttpStatus.ok) {
        await res.drain<void>();
        throw NetworkImageLoadException(statusCode: res.statusCode, uri: uri);
      }
      final builder = BytesBuilder(copy: false);
      final done = Completer<void>();
      _sub = res.listen(
        builder.add,
        onDone: done.complete,
        onError: done.completeError,
        cancelOnError: true,
      );
      await done.future;
      _sub = null;
      _req = null;
      if (gen != _gen || !mounted) return;
      final bytes = builder.takeBytes();
      if (bytes.isEmpty) throw StateError('empty image');
      _kotvPosterByteCachePut(cacheKey, bytes);
      await _decodeAndShow(bytes, tw, th, gen);
    } catch (e) {
      _req = null;
      _sub = null;
      if (gen != _gen || !mounted) return;
      setState(() => _error = e);
    }
  }

  Future<void> _decodeAndShow(Uint8List bytes, int tw, int th, int gen) async {
    ui.Codec? codec;
    try {
      codec = await ui.instantiateImageCodec(bytes, targetWidth: tw, targetHeight: th);
      final frame = await codec.getNextFrame();
      codec.dispose();
      codec = null;
      if (gen != _gen || !mounted) {
        frame.image.dispose();
        return;
      }
      final old = _image;
      setState(() {
        _image = frame.image;
        _error = null;
      });
      old?.dispose();
    } catch (e) {
      codec?.dispose();
      if (gen != _gen || !mounted) return;
      setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final img = _image;
    if (img != null) {
      return RawImage(
        image: img,
        fit: widget.fit,
        filterQuality: FilterQuality.low,
      );
    }
    if (_error != null && widget.errorBuilder != null) {
      return widget.errorBuilder!(context, _error!, StackTrace.empty);
    }
    return const SizedBox.expand();
  }
}
