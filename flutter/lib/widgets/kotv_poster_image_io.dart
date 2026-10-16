import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'kotv_network_image.dart';

/// 压缩字节 LRU：滚回免再下；换源清空。
final LinkedHashMap<String, Uint8List> _posterBytes = LinkedHashMap<String, Uint8List>();
var _posterBytesTotal = 0;
const int _posterBytesMax = 32 << 20; // 32MB

void _posterBytesPut(String urlKey, Uint8List bytes) {
  if (bytes.isEmpty) return;
  final old = _posterBytes.remove(urlKey);
  if (old != null) _posterBytesTotal -= old.length;
  while (_posterBytes.isNotEmpty && _posterBytesTotal + bytes.length > _posterBytesMax) {
    final first = _posterBytes.keys.first;
    final evicted = _posterBytes.remove(first);
    if (evicted != null) _posterBytesTotal -= evicted.length;
  }
  _posterBytes[urlKey] = bytes;
  _posterBytesTotal += bytes.length;
}

Uint8List? _posterBytesGet(String urlKey) {
  final hit = _posterBytes.remove(urlKey);
  if (hit == null) return null;
  _posterBytes[urlKey] = hit;
  return hit;
}

void _posterBytesClear() {
  _posterBytes.clear();
  _posterBytesTotal = 0;
}

/// 解码像素条目：可在清缓存后游离，等最后引用释放再 dispose。
class _PosterDecodedEntry {
  _PosterDecodedEntry(this.image, this.key);

  final ui.Image image;
  final String key;
  int refs = 0;
  bool orphaned = false;

  int get approxBytes => image.width * image.height * 4;
}

final LinkedHashMap<String, _PosterDecodedEntry> _posterDecoded = LinkedHashMap<String, _PosterDecodedEntry>();

/// 无引用解码图像素预算（约 48MB）；有引用永不踢。
const int _posterDecodedUnrefBudget = 48 << 20;

int _fnv1a(Uint8List bytes) {
  var h = 2166136261;
  for (var i = 0; i < bytes.length; i++) {
    h ^= bytes[i];
    h = (h * 16777619) & 0xFFFFFFFF;
  }
  return h;
}

void _posterEvictUnreferenced() {
  var unrefBytes = 0;
  for (final e in _posterDecoded.values) {
    if (e.refs <= 0) unrefBytes += e.approxBytes;
  }
  if (unrefBytes <= _posterDecodedUnrefBudget) return;
  final keys = _posterDecoded.keys.toList();
  for (final key in keys) {
    if (unrefBytes <= _posterDecodedUnrefBudget) break;
    final e = _posterDecoded[key];
    if (e == null || e.refs > 0) continue;
    _posterDecoded.remove(key);
    unrefBytes -= e.approxBytes;
    e.image.dispose();
  }
}

_PosterDecodedEntry? _posterAcquire(String key) {
  final e = _posterDecoded.remove(key);
  if (e == null || e.orphaned) return null;
  e.refs++;
  _posterDecoded[key] = e;
  return e;
}

void _posterRelease(_PosterDecodedEntry e) {
  if (e.refs > 0) e.refs--;
  if (e.refs > 0) return;
  if (e.orphaned || !_posterDecoded.containsKey(e.key) || !identical(_posterDecoded[e.key], e)) {
    e.image.dispose();
    return;
  }
  _posterDecoded.remove(e.key);
  _posterDecoded[e.key] = e;
  _posterEvictUnreferenced();
}

_PosterDecodedEntry _posterPutLive(String key, ui.Image image) {
  final existing = _posterDecoded.remove(key);
  if (existing != null && !existing.orphaned) {
    if (existing.refs > 0) {
      image.dispose();
      existing.refs++;
      _posterDecoded[key] = existing;
      return existing;
    }
    existing.image.dispose();
  }
  final e = _PosterDecodedEntry(image, key)..refs = 1;
  _posterDecoded[key] = e;
  _posterEvictUnreferenced();
  return e;
}

/// 换源/清内存：清空字节池；解码池有引用则 orphan，无引用立即 dispose。
void kotvClearPosterImageCache() {
  _posterBytesClear();
  final live = <_PosterDecodedEntry>[];
  for (final e in _posterDecoded.values) {
    if (e.refs > 0) {
      e.orphaned = true;
      live.add(e);
    } else {
      e.image.dispose();
    }
  }
  _posterDecoded.clear();
  assert(() {
    for (final e in live) {
      assert(e.refs > 0 && e.orphaned);
    }
    return true;
  }());
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
  final double designWidth;
  final double designHeight;

  @override
  State<KotvPosterNetImage> createState() => _KotvPosterNetImageState();
}

class _KotvPosterNetImageState extends State<KotvPosterNetImage> {
  static final HttpClient _client = HttpClient()..autoUncompress = true;

  ui.Image? _image;
  _PosterDecodedEntry? _held;
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
    final e = _held;
    _held = null;
    _image = null;
    if (e != null) _posterRelease(e);
  }

  void _hold(_PosterDecodedEntry e) {
    _held = e;
    _image = e.image;
    _error = null;
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
      final key = 'data|${dataBytes.length}|${_fnv1a(dataBytes)}|$tw|$th';
      await _decodeAndShow(dataBytes, key, tw, th, gen, putBytesKey: null);
      return;
    }

    final parsed = kotvResolveImageRequest(raw);
    if (parsed.url.isEmpty ||
        !(parsed.url.startsWith('http://') || parsed.url.startsWith('https://'))) {
      _error = StateError('bad pic');
      if (mounted && gen == _gen) setState(() {});
      return;
    }

    final urlKey = parsed.url;
    final cacheKey = '$urlKey|$tw|$th';
    final decodedHit = _posterAcquire(cacheKey);
    if (decodedHit != null) {
      if (gen != _gen || !mounted) {
        _posterRelease(decodedHit);
        return;
      }
      setState(() => _hold(decodedHit));
      return;
    }

    final cachedBytes = _posterBytesGet(urlKey);
    if (cachedBytes != null) {
      await _decodeAndShow(cachedBytes, cacheKey, tw, th, gen, putBytesKey: null);
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
      await _decodeAndShow(bytes, cacheKey, tw, th, gen, putBytesKey: urlKey);
    } catch (e) {
      _req = null;
      _sub = null;
      if (gen != _gen || !mounted) return;
      setState(() => _error = e);
    }
  }

  Future<void> _decodeAndShow(
    Uint8List bytes,
    String cacheKey,
    int tw,
    int th,
    int gen, {
    String? putBytesKey,
  }) async {
    ui.Codec? codec;
    try {
      final raced = _posterAcquire(cacheKey);
      if (raced != null) {
        if (putBytesKey != null) _posterBytesPut(putBytesKey, bytes);
        if (gen != _gen || !mounted) {
          _posterRelease(raced);
          return;
        }
        setState(() => _hold(raced));
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

      if (putBytesKey != null) _posterBytesPut(putBytesKey, bytes);
      final entry = _posterPutLive(cacheKey, frame.image);
      setState(() => _hold(entry));
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
