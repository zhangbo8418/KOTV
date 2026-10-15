import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../widgets/kotv_network_image.dart';

String? _cachedUrl;
String? _cachedPath;
Future<void>? _persistFlight;

Future<Directory> _wallDir() async {
  final cache = await getApplicationCacheDirectory();
  final d = Directory(p.join(cache.path, 'wall'));
  if (!d.existsSync()) {
    d.createSync(recursive: true);
  }
  return d;
}

File _currentFile(Directory dir) => File(p.join(dir.path, 'current'));
File _metaFile(Directory dir) => File(p.join(dir.path, 'current.url'));

/// 若磁盘已有该 URL 的壁纸，返回 [FileImage]。
ImageProvider? kotvWallpaperDiskImage(String url) {
  final u = url.trim();
  if (u.isEmpty || _cachedPath == null || _cachedUrl != u) return null;
  final f = File(_cachedPath!);
  if (!f.existsSync()) return null;
  return FileImage(f);
}

/// 冷启动：读上次成功落盘的壁纸。
Future<({String url, String path})?> kotvLoadWallpaperDisk() async {
  try {
    final dir = await _wallDir();
    final meta = _metaFile(dir);
    final file = _currentFile(dir);
    if (!meta.existsSync() || !file.existsSync()) return null;
    final url = (await meta.readAsString()).trim();
    if (url.isEmpty || file.lengthSync() < 32) return null;
    _cachedUrl = url;
    _cachedPath = file.path;
    return (url: url, path: file.path);
  } catch (_) {
    return null;
  }
}

/// 后台拉取并覆盖 `{cache}/wall/current`；同 URL 去重。
Future<void> kotvPersistWallpaper(String url) async {
  final u = url.trim();
  if (u.isEmpty || !(u.startsWith('http://') || u.startsWith('https://'))) return;
  if (_cachedUrl == u && _cachedPath != null && File(_cachedPath!).existsSync()) return;

  final prev = _persistFlight;
  final run = () async {
    if (prev != null) {
      try {
        await prev;
      } catch (_) {}
    }
    try {
      final parsed = kotvResolveImageRequest(u);
      if (parsed.url.isEmpty) return;
      final client = HttpClient()..autoUncompress = true;
      try {
        final req = await client.getUrl(Uri.parse(parsed.url));
        parsed.headers.forEach(req.headers.set);
        final res = await req.close().timeout(const Duration(seconds: 30));
        if (res.statusCode != HttpStatus.ok) {
          await res.drain<void>();
          return;
        }
        final bytes = await consolidateHttpClientResponseBytes(res);
        if (bytes.length < 32) return;
        final dir = await _wallDir();
        final tmp = File(p.join(dir.path, 'current.tmp'));
        await tmp.writeAsBytes(bytes, flush: true);
        final dest = _currentFile(dir);
        if (dest.existsSync()) {
          try {
            dest.deleteSync();
          } catch (_) {}
        }
        await tmp.rename(dest.path);
        await _metaFile(dir).writeAsString(u, flush: true);
        _cachedUrl = u;
        _cachedPath = dest.path;
      } finally {
        client.close(force: true);
      }
    } catch (_) {}
  }();
  _persistFlight = run;
  await run;
}

Future<void> kotvClearWallpaperDisk() async {
  _cachedUrl = null;
  _cachedPath = null;
  try {
    final dir = await _wallDir();
    for (final f in [_currentFile(dir), _metaFile(dir), File(p.join(dir.path, 'current.tmp'))]) {
      if (f.existsSync()) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
    }
  } catch (_) {}
}
