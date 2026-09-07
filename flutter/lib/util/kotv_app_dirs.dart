import 'kotv_io.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 与 Go `internal/paths.Root` 同一数据根。
///
/// | 平台 | 根目录 |
/// |------|--------|
/// | Windows | `%APPDATA%/KOTV` |
/// | macOS | `~/Library/Application Support/KOTV` |
/// | Linux | `~/.local/share/KOTV` |
/// | Android | 应用 cache/`KOTV`（与引擎 `KOTV_DATA_DIR` 一致） |
Future<Directory> kotvDataRoot() async {
  if (kIsWeb) {
    return Directory.systemTemp;
  }
  if (Platform.isAndroid) {
    return _androidDataRoot();
  }
  return kotvDataRootSync();
}

/// 同步版数据根（桌面错误落盘等不能 await 的路径）。
Directory kotvDataRootSync() {
  if (kIsWeb) {
    return Directory.systemTemp;
  }
  final env = Platform.environment['KOTV_DATA_DIR']?.trim() ?? '';
  if (env.isNotEmpty) {
    return _ensureDir(env);
  }
  final cacheEnv = Platform.environment['KOTV_CACHE_DIR']?.trim() ?? '';
  if (cacheEnv.isNotEmpty) {
    return _ensureDir(cacheEnv);
  }
  if (Platform.isAndroid) {
    return _ensureDir(p.join(Directory.systemTemp.path, 'KOTV'));
  }
  if (Platform.isWindows) {
    var base = Platform.environment['APPDATA']?.trim() ?? '';
    if (base.isEmpty) {
      final profile = Platform.environment['USERPROFILE']?.trim() ?? '';
      base = p.join(profile, 'AppData', 'Roaming');
    }
    return _ensureDir(p.join(base, 'KOTV'));
  }
  if (Platform.isMacOS) {
    final home = Platform.environment['HOME']?.trim() ?? '';
    return _ensureDir(p.join(home, 'Library', 'Application Support', 'KOTV'));
  }
  final home = Platform.environment['HOME']?.trim() ?? '';
  return _ensureDir(p.join(home, '.local', 'share', 'KOTV'));
}

/// UI 临时文件：启动日志、看门狗脚本等 → `{Root}/ui`。
Future<Directory> kotvUiDir() async {
  return _ensureDir(p.join((await kotvDataRoot()).path, 'ui'));
}

Directory kotvUiDirSync() => _ensureDir(p.join(kotvDataRootSync().path, 'ui'));

/// 日志目录：与引擎 `paths.LogDir` 相同 → `{Root}/data/log`。
Future<Directory> kotvLogDir() async {
  return _ensureDir(p.join((await kotvDataRoot()).path, 'data', 'log'));
}

Directory kotvLogDirSync() => _ensureDir(p.join(kotvDataRootSync().path, 'data', 'log'));

Directory _ensureDir(String path) {
  final d = Directory(path);
  if (!d.existsSync()) {
    d.createSync(recursive: true);
  }
  return d;
}

Future<Directory> _androidDataRoot() async {
  try {
    const ch = MethodChannel('kotv_android_spider');
    final raw = await ch.invokeMethod<dynamic>('paths');
    if (raw is Map) {
      final cache = '${raw['cacheDir'] ?? ''}'.trim();
      if (cache.isNotEmpty) {
        return _ensureDir(p.join(cache, 'KOTV'));
      }
    }
  } catch (_) {}
  final support = await getApplicationSupportDirectory();
  return _ensureDir(p.join(support.path, 'KOTV'));
}
