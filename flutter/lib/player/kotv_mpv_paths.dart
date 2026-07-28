import 'dart:io';

import 'package:path/path.dart' as p;

/// 解析捆绑 libmpv（与 Go 引擎、runtime 布局一致）。
class KotvMpvPaths {
  static Iterable<String> _runtimeRoots() sync* {
    final env = Platform.environment['KOTV_RUNTIME'];
    if (env != null && env.trim().isNotEmpty) {
      yield p.normalize(env.trim());
    }

    for (final start in [
      Directory.current.path,
      p.dirname(Platform.resolvedExecutable),
    ]) {
      var dir = p.normalize(start);
      for (var i = 0; i < 10; i++) {
        yield p.normalize(p.join(dir, 'runtime'));
        yield p.normalize(p.join(dir, 'Resources', 'runtime'));
        final parent = p.dirname(dir);
        if (parent == dir) break;
        dir = parent;
      }
    }

    final exeDir = p.dirname(Platform.resolvedExecutable);
    yield p.normalize(p.join(exeDir, 'runtime'));
    yield p.normalize(p.join(exeDir, '..', 'runtime'));
    yield p.normalize(p.join(exeDir, '..', 'Resources', 'runtime'));
    yield p.normalize(p.join(exeDir, '..', '..', 'runtime'));
  }

  static List<String> _libNames() {
    if (Platform.isWindows) {
      return ['libmpv-2.dll', 'mpv-2.dll'];
    }
    if (Platform.isLinux) {
      return ['libmpv.so.2', 'libmpv.so'];
    }
    if (Platform.isMacOS) {
      return ['libmpv.dylib', 'libmpv.2.dylib', 'libmpv.1.dylib'];
    }
    return const [];
  }

  /// 返回 libmpv 动态库绝对路径；找不到则为 null。
  static String? resolveLibPath() {
    final seen = <String>{};
    for (final root in _runtimeRoots()) {
      if (!seen.add(root)) continue;
      for (final name in _libNames()) {
        final file = File(p.join(root, 'libmpv', name));
        if (file.existsSync()) return file.path;
      }
    }
    return null;
  }
}
