import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../widgets/kotv_network_image.dart';

String? _cachedUrl;
String? _cachedPath;
Future<void>? _ioFlight;

Future<T> _withWallLock<T>(Future<T> Function() body) async {
  final prev = _ioFlight;
  final done = Completer<void>();
  _ioFlight = done.future;
  if (prev != null) {
    try {
      await prev;
    } catch (_) {}
  }
  try {
    return await body();
  } finally {
    if (!done.isCompleted) done.complete();
  }
}

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

bool _looksLikeImage(Uint8List bytes) {
  if (bytes.length < 12) return false;
  if (bytes[0] == 0xFF && bytes[1] == 0xD8) return true;
  if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) {
    return true;
  }
  if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) return true;
  if (bytes[0] == 0x42 && bytes[1] == 0x4D) return true;
  return bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50;
}

/// 读出已落盘的壁纸字节。Windows 用内存图显示，避免解码期间占着文件。
Future<Uint8List?> kotvReadWallpaperBytes(String url) {
  return _withWallLock(() async {
    final u = url.trim();
    if (u.isEmpty || _cachedPath == null || _cachedUrl != u) return null;
    final f = File(_cachedPath!);
    if (!f.existsSync() || f.lengthSync() < 32) return null;
    final bytes = await f.readAsBytes();
    if (!_looksLikeImage(bytes)) return null;
    return bytes;
  });
}

/// 冷启动：读上次成功落盘的壁纸。current 被占用时会落在 current.hold。
Future<({String url, String path})?> kotvLoadWallpaperDisk() {
  return _withWallLock(() async {
    try {
      final dir = await _wallDir();
      final meta = _metaFile(dir);
      if (!meta.existsSync()) return null;
      final url = (await meta.readAsString()).trim();
      if (url.isEmpty) return null;
      final candidates = [
        _currentFile(dir),
        File(p.join(dir.path, 'current.hold')),
      ];
      File? best;
      for (final f in candidates) {
        if (!f.existsSync() || f.lengthSync() < 32) continue;
        if (best == null ||
            f.lastModifiedSync().isAfter(best.lastModifiedSync())) {
          best = f;
        }
      }
      if (best == null) return null;
      _cachedUrl = url;
      _cachedPath = best.path;
      return (url: url, path: best.path);
    } catch (_) {
      return null;
    }
  });
}

/// 后台拉取并写入 `{cache}/wall/`；同 URL 去重。
/// 正在被读的文件不先删掉，避免 Windows 上画面跟着文件一起没了。
Future<void> kotvPersistWallpaper(String url) {
  final u = url.trim();
  if (u.isEmpty || !(u.startsWith('http://') || u.startsWith('https://'))) {
    return Future<void>.value();
  }
  return _withWallLock(() async {
    if (_cachedUrl == u && _cachedPath != null && File(_cachedPath!).existsSync()) {
      return;
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
        if (!_looksLikeImage(bytes)) return;
        final dir = await _wallDir();
        final tmp = File(p.join(dir.path, 'current.tmp'));
        await tmp.writeAsBytes(bytes, flush: true);
        final dest = _currentFile(dir);
        var stored = dest;
        if (dest.existsSync()) {
          try {
            dest.deleteSync();
          } catch (_) {
            stored = File(p.join(dir.path, 'current.hold'));
          }
        }
        try {
          if (stored.path != dest.path && stored.existsSync()) {
            stored.deleteSync();
          }
          await tmp.rename(stored.path);
        } catch (_) {
          final data = await tmp.readAsBytes();
          await stored.writeAsBytes(data, flush: true);
          try {
            await tmp.delete();
          } catch (_) {}
        }
        await _metaFile(dir).writeAsString(u, flush: true);
        _cachedUrl = u;
        _cachedPath = stored.path;
      } finally {
        client.close(force: true);
      }
    } catch (_) {}
  });
}

Future<void> kotvClearWallpaperDisk() {
  return _withWallLock(() async {
    _cachedUrl = null;
    _cachedPath = null;
    try {
      final dir = await _wallDir();
      for (final f in [
        _currentFile(dir),
        _metaFile(dir),
        File(p.join(dir.path, 'current.tmp')),
        File(p.join(dir.path, 'current.hold')),
      ]) {
        if (f.existsSync()) {
          try {
            f.deleteSync();
          } catch (_) {}
        }
      }
    } catch (_) {}
  });
}
