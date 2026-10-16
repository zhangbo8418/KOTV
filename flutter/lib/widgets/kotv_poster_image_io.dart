import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'kotv_network_image.dart';

/// 解码像素缓存：滚回同 URL+桶命中；无引用时可淘汰回落；换源可整清。
class _PosterDecodedEntry {
  _PosterDecodedEntry(this.image);

  final ui.Image image;
  int refs = 0;
}

final LinkedHashMap<String, _PosterDecodedEntry> _posterDecoded = LinkedHashMap<String, _PosterDecodedEntry>();

/// 无引用条目上限：供近距滚回命中；超出则 dispose 最旧无引用图。
const int _posterUnreferencedMax = 48;

void _posterEvictUnreferenced() {
  var unreferenced = 0;
  for (final e in _posterDecoded.values) {
    if (e.refs <= 0) unreferenced++;
  }
  if (unreferenced <= _posterUnreferencedMax) return;
  final keys = _posterDecoded.keys.toList();
  for (final key in keys) {
    if (unreferenced <= _posterUnreferencedMax) break;
    final e = _posterDecoded[key];
    if (e == null || e.refs > 0) continue;
    _posterDecoded.remove(key);
    e.image.dispose();
    unreferenced--;
  }
}

ui.Image? _posterAcquire(String key) {
  final e = _posterDecoded.remove(key);
  if (e == null) return null;
  e.refs++;
  _posterDecoded[key] = e;
  return e.image;
}

void _posterRelease(String key) {
  final e = _posterDecoded[key];
  if (e == null) return;
  if (e.refs > 0) e.refs--;
  if (e.refs <= 0) {
    _posterDecoded.remove(key);
    _posterDecoded[key] = e;
    _posterEvictUnreferenced();
  }
}

/// 入库并占用 1 引用；若 key 已有存活条目则沿用并 dispose 重复解码。
ui.Image _posterPutLive(String key, ui.Image image) {
  final existing = _posterDecoded.remove(key);
  if (existing != null) {
    if (existing.refs > 0) {
      image.dispose();
      existing.refs++;
      _posterDecoded[key] = existing;
      return existing.image;
    }
    existing.image.dispose();
  }
  final e = _PosterDecodedEntry(image)..refs = 1;
  _posterDecoded[key] = e;
  _posterEvictUnreferenced();
  return image;
}

/// 换源/清内存：释放全部海报解码像素。
void kotvClearPosterImageCache() {
  for (final e in _posterDecoded.values) {
    e.image.dispose();
  }
  _posterDecoded.clear();
}

/// 列表海报：State 自管 HttpClient，[dispose] 时 abort；解码图进引用计数缓存。
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
  String? _heldKey;
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
    _dropHeld();
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

  void _dropHeld() {
    final key = _heldKey;
    _heldKey = null;
    _image = null;
    if (key != null) _posterRelease(key);
  }

  Future<void> _load() async {
    final gen = ++_gen;
    _abort();
    _dropHeld();
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
      await _decodeAndShow(dataBytes, tw, th, 'data|${raw.hashCode}|$tw|$th', gen);
      return;
    }

    final parsed = kotvResolveImageRequest(raw);
    if (parsed.url.isEmpty ||
        !(parsed.url.startsWith('http://') || parsed.url.startsWith('https://'))) {
      _error = StateError('bad pic');
      if (mounted && gen == _gen) setState(() {});
      return;
    }

    final cacheKey = '${parsed.url}|$tw|$th';
    final hit = _posterAcquire(cacheKey);
    if (hit != null) {
      if (gen != _gen || !mounted) {
        _posterRelease(cacheKey);
        return;
      }
      setState(() {
        _heldKey = cacheKey;
        _image = hit;
        _error = null;
      });
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
      await _decodeAndShow(bytes, tw, th, cacheKey, gen);
    } catch (e) {
      _req = null;
      _sub = null;
      if (gen != _gen || !mounted) return;
      setState(() => _error = e);
    }
  }

  Future<void> _decodeAndShow(Uint8List bytes, int tw, int th, String cacheKey, int gen) async {
    ui.Codec? codec;
    try {
      final raced = _posterAcquire(cacheKey);
      if (raced != null) {
        if (gen != _gen || !mounted) {
          _posterRelease(cacheKey);
          return;
        }
        setState(() {
          _heldKey = cacheKey;
          _image = raced;
          _error = null;
        });
        return;
      }

      codec = await ui.instantiateImageCodec(bytes, targetWidth: tw, targetHeight: th);
      final frame = await codec.getNextFrame();
      codec.dispose();
      codec = null;
      if (gen != _gen || !mounted) {
        frame.image.dispose();
        return;
      }

      final shown = _posterPutLive(cacheKey, frame.image);
      setState(() {
        _heldKey = cacheKey;
        _image = shown;
        _error = null;
      });
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
