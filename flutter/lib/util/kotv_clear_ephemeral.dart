import '../util/kotv_io.dart';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

bool _isFlutterEphemeralName(String name) {
  final low = name.toLowerCase();
  if (low.startsWith('kotv-')) return true;
  if (low.endsWith('.log')) return true;
  if (low.endsWith('.vbs') && low.contains('kotv')) return true;
  return false;
}

/// 清理 Flutter / path_provider 侧可再生文件（不含 SharedPreferences 与用户文档）。
///
/// Windows 上引擎数据在 `%APPDATA%/KOTV`，UI 支持目录在
/// `%APPDATA%/com.bobo/KO Yingshi`（公司名+产品名），两套互不覆盖；
/// 设置页「清理缓存」需两边都清。
Future<int> kotvClearFlutterEphemeral() async {
  var n = 0;
  Future<void> wipeEntry(FileSystemEntity e) async {
    try {
      if (e is Directory) {
        await e.delete(recursive: true);
      } else {
        await e.delete();
      }
      n++;
    } catch (_) {}
  }

  Future<void> scrubDir(Directory dir, {required bool Function(String name) match}) async {
    if (!await dir.exists()) return;
    await for (final e in dir.list(followLinks: false)) {
      final name = p.basename(e.path);
      if (!match(name)) continue;
      await wipeEntry(e);
    }
  }

  try {
    final support = await getApplicationSupportDirectory();
    await scrubDir(Directory(support.path), match: _isFlutterEphemeralName);
  } catch (_) {}

  try {
    final tmp = await getTemporaryDirectory();
    await scrubDir(Directory(tmp.path), match: _isFlutterEphemeralName);
  } catch (_) {}

  try {
    final cache = await getApplicationCacheDirectory();
    if (await cache.exists()) {
      await for (final e in cache.list(followLinks: false)) {
        await wipeEntry(e);
      }
    }
  } catch (_) {}

  return n;
}
