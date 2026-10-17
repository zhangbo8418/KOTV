import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'kotv_network_image.dart';

/// 压缩字节 LRU：滚回免再下；换源清空。
final LinkedHashMap<String, Uint8List> _posterBytes =
    LinkedHashMap<String, Uint8List>();
var _posterBytesTotal = 0;
const int _posterBytesMax = 32 << 20; // 32MB

void _posterBytesPut(String urlKey, Uint8List bytes) {
  if (bytes.isEmpty || bytes.length > _posterBytesMax) return;
  final old = _posterBytes.remove(urlKey);
  if (old != null) _posterBytesTotal -= old.length;
  while (_posterBytes.isNotEmpty &&
      _posterBytesTotal + bytes.length > _posterBytesMax) {
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

void _posterBytesRemove(String urlKey) {
  final old = _posterBytes.remove(urlKey);
  if (old != null) _posterBytesTotal -= old.length;
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

final LinkedHashMap<String, _PosterDecodedEntry> _posterDecoded =
    LinkedHashMap<String, _PosterDecodedEntry>();

/// 无引用解码图像素预算（约 48MB）；有引用（视口内）由格子 dispose 释放后再纳入本预算淘汰。
const int _posterDecodedUnrefBudget = 48 << 20;

/// 同时解码上限，避免飞滚时 codec 打满主线程。
const int _posterDecodeMaxInflight = 4;
var _posterDecodeInflight = 0;
final List<Completer<void>> _posterDecodeWait = <Completer<void>>[];

Future<void> _posterDecodeAcquire() async {
  if (_posterDecodeInflight < _posterDecodeMaxInflight) {
    _posterDecodeInflight++;
    return;
  }
  final c = Completer<void>();
  _posterDecodeWait.add(c);
  await c.future;
}

void _posterDecodeRelease() {
  if (_posterDecodeWait.isNotEmpty) {
    _posterDecodeWait.removeAt(0).complete();
    return;
  }
  if (_posterDecodeInflight > 0) _posterDecodeInflight--;
}

int _fnv1a(Uint8List bytes) {
  var h = 2166136261;
  for (var i = 0; i < bytes.length; i++) {
    h ^= bytes[i];
    h = (h * 16777619) & 0xFFFFFFFF;
  }
  return h;
}

String _headersFingerprint(Map<String, String> headers) {
  if (headers.isEmpty) return '';
  final keys = headers.keys.toList()..sort();
  final b = StringBuffer();
  for (final k in keys) {
    b.write(k);
    b.write('=');
    b.write(headers[k]);
    b.write(';');
  }
  return '${_fnv1a(Uint8List.fromList(b.toString().codeUnits))}';
}

/// 逻辑尺寸量化到 16px 桶，减少同列格子 key 碎片，便于滚回命中。
double kotvPosterDesignBucket(double logical, {double max = 214}) {
  if (!(logical > 0)) return max;
  final stepped = ((logical + 15) ~/ 16) * 16;
  return stepped.clamp(48, max).toDouble();
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
  if (e == null) return null;
  if (e.orphaned) {
    e.image.dispose();
    return null;
  }
  e.refs++;
  _posterDecoded[key] = e;
  return e;
}

void _posterRelease(_PosterDecodedEntry e) {
  if (e.refs > 0) e.refs--;
  if (e.refs > 0) return;
  if (e.orphaned ||
      !_posterDecoded.containsKey(e.key) ||
      !identical(_posterDecoded[e.key], e)) {
    e.image.dispose();
    return;
  }
  // LRU：挪到尾部；超预算再踢最旧无引用项。
  _posterDecoded.remove(e.key);
  _posterDecoded[e.key] = e;
  _posterEvictUnreferenced();
}

/// [initialRefs] 为 0 时表示仅入池（格子已卸树），供滚回命中。
_PosterDecodedEntry _posterPut(String key, ui.Image image,
    {required int initialRefs}) {
  final existing = _posterDecoded.remove(key);
  if (existing != null && !existing.orphaned) {
    if (existing.refs > 0) {
      image.dispose();
      if (initialRefs > 0) existing.refs++;
      _posterDecoded[key] = existing;
      return existing;
    }
    existing.image.dispose();
  }
  final e = _PosterDecodedEntry(image, key)
    ..refs = initialRefs < 0 ? 0 : initialRefs;
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

class _PosterLoadAborted implements Exception {
  const _PosterLoadAborted();
}

/// 列表海报：State 自管 HttpClient，[dispose] 时 abort；解码图进引用计数缓存。
class KotvPosterNetImage extends StatefulWidget {
  const KotvPosterNetImage(
    this.pic, {
    super.key,
    this.fit = BoxFit.cover,
    this.errorBuilder,
    this.designWidth = 214,
  });

  final String pic;
  final BoxFit fit;
  final ImageErrorWidgetBuilder? errorBuilder;
  final double designWidth;

  @override
  State<KotvPosterNetImage> createState() => _KotvPosterNetImageState();
}

class _KotvPosterNetImageState extends State<KotvPosterNetImage> {
  static final HttpClient _client = HttpClient()
    ..autoUncompress = true
    ..maxConnectionsPerHost = 6;

  ui.Image? _image;
  _PosterDecodedEntry? _held;
  Object? _error;
  int _gen = 0;
  HttpClientRequest? _req;
  StreamSubscription<List<int>>? _sub;
  Completer<void>? _bodyDone;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(KotvPosterNetImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pic != widget.pic ||
        oldWidget.designWidth != widget.designWidth) {
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
    final done = _bodyDone;
    _bodyDone = null;
    if (done != null && !done.isCompleted) {
      done.completeError(const _PosterLoadAborted());
    }
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

  void _swapHold(_PosterDecodedEntry e) {
    final prev = _held;
    _hold(e);
    if (prev != null && !identical(prev, e)) _posterRelease(prev);
  }

  Future<void> _load() async {
    final gen = ++_gen;
    _abort();

    final raw = widget.pic.trim();
    if (raw.isEmpty) {
      _dropHeld();
      _error = StateError('empty pic');
      if (mounted && gen == _gen) setState(() {});
      return;
    }

    if (!mounted) return;
    final dpr = View.of(context).devicePixelRatio;
    final tw = (widget.designWidth * dpr).round().clamp(1, 720);

    final dataBytes = kotvDecodeDataImage(raw);
    if (dataBytes != null) {
      final key = 'data|${dataBytes.length}|${_fnv1a(dataBytes)}|$tw';
      final hit = _posterAcquire(key);
      if (hit != null) {
        if (gen != _gen || !mounted) {
          _posterRelease(hit);
          return;
        }
        _swapHold(hit);
        setState(() {});
        return;
      }
      // 有字节可解：保留旧图直到新帧，避免滚回闪白。
      await _decodeAndShow(dataBytes, key, tw, gen);
      return;
    }

    final parsed = kotvResolveImageRequest(raw);
    if (parsed.url.isEmpty ||
        !(parsed.url.startsWith('http://') ||
            parsed.url.startsWith('https://'))) {
      _dropHeld();
      _error = StateError('bad pic');
      if (mounted && gen == _gen) setState(() {});
      return;
    }

    final hdrFp = _headersFingerprint(parsed.headers);
    final urlKey = hdrFp.isEmpty ? parsed.url : '${parsed.url}|h:$hdrFp';
    final cacheKey = '$urlKey|$tw';

    // 先同步拿解码池：命中则无缝换图，避免滚回先闪空白。
    final decodedHit = _posterAcquire(cacheKey);
    if (decodedHit != null) {
      if (gen != _gen || !mounted) {
        _posterRelease(decodedHit);
        return;
      }
      _swapHold(decodedHit);
      setState(() {});
      return;
    }

    final cachedBytes = _posterBytesGet(urlKey);
    if (cachedBytes != null) {
      // 字节命中：不解空白，旧图留到解码完成。
      await _decodeAndShow(cachedBytes, cacheKey, tw, gen, bytesKey: urlKey);
      return;
    }

    _blankIfNeeded();

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
      if (res.statusCode != HttpStatus.ok) {
        await res.drain<void>();
        throw NetworkImageLoadException(statusCode: res.statusCode, uri: uri);
      }
      final builder = BytesBuilder(copy: false);
      final done = Completer<void>();
      _bodyDone = done;
      _sub = res.listen(
        builder.add,
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        onError: (Object e, StackTrace st) {
          if (!done.isCompleted) done.completeError(e, st);
        },
        cancelOnError: true,
      );
      try {
        await done.future;
      } on _PosterLoadAborted {
        return;
      } finally {
        if (identical(_bodyDone, done)) _bodyDone = null;
        _sub = null;
        _req = null;
      }
      final bytes = builder.takeBytes();
      if (bytes.isEmpty) throw StateError('empty image');
      // 即使格子已回收，仍入字节池，供滚回免再下。
      _posterBytesPut(urlKey, bytes);
      // 格子已卸也继续解码入池，避免滚回只剩字节命中再卡一帧。
      await _decodeAndShow(bytes, cacheKey, tw, gen, bytesKey: urlKey);
    } on _PosterLoadAborted {
      return;
    } catch (e) {
      _req = null;
      _sub = null;
      _bodyDone = null;
      if (gen != _gen || !mounted) return;
      setState(() => _error = e);
    }
  }

  void _blankIfNeeded() {
    if (_held == null && _error == null) return;
    _dropHeld();
    _error = null;
    if (mounted) setState(() {});
  }

  Future<void> _decodeAndShow(
    Uint8List bytes,
    String cacheKey,
    int tw,
    int gen, {
    String? bytesKey,
  }) async {
    ui.Codec? codec;
    var gateHeld = false;
    try {
      final raced = _posterAcquire(cacheKey);
      if (raced != null) {
        if (gen != _gen || !mounted) {
          _posterRelease(raced);
          return;
        }
        _swapHold(raced);
        setState(() {});
        return;
      }

      await _posterDecodeAcquire();
      gateHeld = true;
      if (gen != _gen) {
        // 世代已变：仍解码入池，不挂到本 State。
      }

      codec = await ui.instantiateImageCodec(bytes, targetWidth: tw);
      final frame = await codec.getNextFrame();
      codec.dispose();
      codec = null;

      final hold = gen == _gen && mounted;
      final entry =
          _posterPut(cacheKey, frame.image, initialRefs: hold ? 1 : 0);
      if (!hold) return;
      _swapHold(entry);
      setState(() {});
    } catch (e) {
      codec?.dispose();
      if (bytesKey != null) _posterBytesRemove(bytesKey);
      if (gen != _gen || !mounted) return;
      setState(() => _error = e);
    } finally {
      if (gateHeld) _posterDecodeRelease();
    }
  }

  @override
  Widget build(BuildContext context) {
    final img = _image;
    if (img != null) {
      return RawImage(
        // 卸树时 RawImage 会 dispose 句柄；池里留原件，这里只交副本。
        image: img.clone(),
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
