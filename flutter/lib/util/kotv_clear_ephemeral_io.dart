import 'kotv_app_dirs.dart';
import 'kotv_io.dart';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

bool _isFlutterEphemeralName(String name) {
  final low = name.toLowerCase();
  if (low.startsWith('kotv-')) return true;
  if (low.endsWith('.log')) return true;
  if (low.endsWith('.vbs') && low.contains('kotv')) return true;
  return false;
}

/// 清理 Flutter / 引擎旁可再生文件（不含 setting.ini、数据库、SharedPreferences）。
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
    await scrubDir(await kotvUiDir(), match: (_) => true);
  } catch (_) {}

  try {
    await scrubDir(await kotvLogDir(), match: (name) {
      final low = name.toLowerCase();
      return low.startsWith('kotv-') ||
          low.startsWith('flutter') ||
          low == 'kotv-mpv.log' ||
          low.endsWith('.err.log');
    });
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
