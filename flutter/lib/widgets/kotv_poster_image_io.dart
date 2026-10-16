import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'kotv_network_image.dart';

/// 解码像素条目：可在清缓存后游离，等最后引用释放再 dispose。
class _PosterDecodedEntry {
  _PosterDecodedEntry(this.image, this.key);

  final ui.Image image;
  final String key;
  int refs = 0;
  /// 已从可命中池摘掉（换源清空）；不再被 acquire，仅等 refs 归零后释放。
  bool orphaned = false;
}

final LinkedHashMap<String, _PosterDecodedEntry> _posterDecoded = LinkedHashMap<String, _PosterDecodedEntry>();

/// 无引用条目上限：供近距滚回命中；超出则 dispose 最旧无引用图。
const int _posterUnreferencedMax = 48;

int _fnv1a(Uint8List bytes) {
  var h = 2166136261;
  for (var i = 0; i < bytes.length; i++) {
    h ^= bytes[i];
    h = (h * 16777619) & 0xFFFFFFFF;
  }
  return h;
}

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
  // 仍在池内：移到末尾，供滚回；超额再淘汰。
  _posterDecoded.remove(e.key);
  _posterDecoded[e.key] = e;
  _posterEvictUnreferenced();
}

/// 入库并占用 1 引用；若 key 已有存活条目则沿用并 dispose 重复解码。
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

/// 换源/清内存：可命中池清空；仍在画的条目标 orphan，等 State 释放后再 dispose。
void kotvClearPosterImageCache() {
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
  // live 仅由各 State._held 持有；不再进入可命中池。
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
  /// 与网格 childAspectRatio 214/286 一致，解码键稳定。
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
      await _decodeAndShow(dataBytes, key, tw, th, gen);
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
        _posterRelease(hit);
        return;
      }
      setState(() => _hold(hit));
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
      await _decodeAndShow(bytes, cacheKey, tw, th, gen);
    } catch (e) {
      _req = null;
      _sub = null;
      if (gen != _gen || !mounted) return;
      setState(() => _error = e);
    }
  }

  Future<void> _decodeAndShow(Uint8List bytes, String cacheKey, int tw, int th, int gen) async {
    ui.Codec? codec;
    try {
      final raced = _posterAcquire(cacheKey);
      if (raced != null) {
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
