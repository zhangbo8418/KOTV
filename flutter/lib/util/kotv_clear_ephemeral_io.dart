import 'kotv_app_dirs.dart';
import 'kotv_io.dart';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

bool _isFlutterEphemeralName(String name) {
  final low = name.toLowerCase();
  if (low == 'kotv' || low == 'db') return false;
  if (low.startsWith('kotv-')) return true;
  if (low.endsWith('.log')) return true;
  if (low.endsWith('.vbs') && low.contains('kotv')) return true;
  return false;
}

bool _isProtectedDataRootName(String name) {
  final low = name.toLowerCase();
  return low == 'kotv' || low == 'db';
}

/// 清理 Flutter / 引擎旁可再生文件（不含数据库；保留 ui/client.json 鉴权与引擎地址）。
///
/// 绝不删除 [kotvDataRoot] 下的 db/setting（Android 上曾误整清 cacheDir 把多仓 DB 一起删掉）。
Future<int> kotvClearFlutterEphemeral() async {
  var n = 0;
  String? dataRootPath;
  try {
    dataRootPath = p.normalize((await kotvDataRoot()).path);
  } catch (_) {}

  bool isDataRootOrProtected(String path) {
    final root = dataRootPath;
    final name = p.basename(path);
    if (_isProtectedDataRootName(name)) return true;
    if (name.toLowerCase() == 'client.json') return true;
    if (root == null || root.isEmpty) return false;
    final norm = p.normalize(path);
    return norm == root;
  }

  Future<void> wipeEntry(FileSystemEntity e, {required bool protectDataRoot}) async {
    if (protectDataRoot && (isDataRootOrProtected(e.path) || _isProtectedDataRootName(p.basename(e.path)))) {
      return;
    }
    // 即便 scrub ui/log，也绝不动 db / client.json。
    if (_isProtectedDataRootName(p.basename(e.path))) return;
    if (p.basename(e.path).toLowerCase() == 'client.json') return;
    try {
      if (e is Directory) {
        await e.delete(recursive: true);
      } else {
        await e.delete();
      }
      n++;
    } catch (_) {}
  }

  Future<void> scrubDir(
    Directory dir, {
    required bool Function(String name) match,
    required bool protectDataRoot,
  }) async {
    if (!await dir.exists()) return;
    await for (final e in dir.list(followLinks: false)) {
      final name = p.basename(e.path);
      if (!match(name)) continue;
      await wipeEntry(e, protectDataRoot: protectDataRoot);
    }
  }

  try {
    await scrubDir(
      await kotvUiDir(),
      match: (name) => name.toLowerCase() != 'client.json',
      protectDataRoot: false,
    );
  } catch (_) {}

  try {
    await scrubDir(await kotvLogDir(), match: (name) {
      final low = name.toLowerCase();
      return low.startsWith('kotv-') ||
          low.startsWith('flutter') ||
          low.endsWith('.err.log');
    }, protectDataRoot: false);
  } catch (_) {}

  try {
    final tmp = await getTemporaryDirectory();
    await scrubDir(Directory(tmp.path), match: _isFlutterEphemeralName, protectDataRoot: true);
  } catch (_) {}

  // ApplicationCacheDirectory 在 Android 即 cacheDir；数据根曾落在其下，
  // 禁止整树清空，只清明显的临时文件名。
  try {
    final cache = await getApplicationCacheDirectory();
    await scrubDir(Directory(cache.path), match: _isFlutterEphemeralName, protectDataRoot: true);
  } catch (_) {}

  return n;
}
