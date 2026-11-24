import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// `{cache}/wall/current` 存图，`current.url` 存来源地址，文件修改时间即取图时间。
Future<Directory> _wallDir() async {
  final cache = await getApplicationCacheDirectory();
  return Directory(p.join(cache.path, 'wall'));
}

Future<({String url, Uint8List bytes, DateTime fetchedAt})?> wallDiskLoad() async {
  final dir = await _wallDir();
  final img = File(p.join(dir.path, 'current'));
  final meta = File(p.join(dir.path, 'current.url'));
  if (!img.existsSync() || !meta.existsSync()) return null;
  final url = (await meta.readAsString()).trim();
  if (url.isEmpty) return null;
  return (url: url, bytes: await img.readAsBytes(), fetchedAt: img.lastModifiedSync());
}

/// 先写临时文件再改名，中途退出不会留下半张图。
Future<void> wallDiskSave(String url, Uint8List bytes) async {
  final dir = await _wallDir();
  await dir.create(recursive: true);
  final tmp = File(p.join(dir.path, 'current.tmp'));
  await tmp.writeAsBytes(bytes, flush: true);
  await tmp.rename(p.join(dir.path, 'current'));
  await File(p.join(dir.path, 'current.url')).writeAsString(url, flush: true);
}

Future<void> wallDiskClear() async {
  final dir = await _wallDir();
  if (dir.existsSync()) await dir.delete(recursive: true);
}
