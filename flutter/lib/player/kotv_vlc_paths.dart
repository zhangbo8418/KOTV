import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../util/kotv_io.dart';

/// 解析捆绑 libvlc 目录（与引擎 runtime 布局一致）。
class KotvVlcPaths {
  static String? resolveLibDir() {
    if (kIsWeb) return null;
    final env = Platform.environment['KOTV_RUNTIME'];
    final candidates = <String>{};

    void addRoot(String? root) {
      if (root == null || root.isEmpty) return;
      candidates.add(p.normalize(root));
    }

    addRoot(env);

    // 从 cwd / 可执行文件目录向上扫，覆盖 flutter run、.app、发行包。
    for (final start in [
      Directory.current.path,
      p.dirname(Platform.resolvedExecutable),
    ]) {
      var dir = p.normalize(start);
      for (var i = 0; i < 10; i++) {
        addRoot(p.join(dir, 'runtime'));
        addRoot(p.join(dir, 'Resources', 'runtime'));
        final parent = p.dirname(dir);
        if (parent == dir) break;
        dir = parent;
      }
    }

    final exeDir = p.dirname(Platform.resolvedExecutable);
    addRoot(p.join(exeDir, '..', 'Resources', 'runtime'));
    addRoot(p.join(exeDir, 'runtime'));
    addRoot(p.join(exeDir, '..', 'runtime'));
    addRoot(p.join(exeDir, '..', '..', 'runtime'));

    final libNames = Platform.isWindows
        ? ['libvlc.dll']
        : Platform.isLinux
            ? ['libvlc.so', 'libvlc.so.5', 'libvlc.so.6']
            : ['libvlc.dylib', 'libvlc.5.dylib'];

    for (final root in candidates) {
      for (final name in libNames) {
        final lib = File(p.join(root, 'libvlc', name));
        if (lib.existsSync()) return p.dirname(lib.path);
      }
      if (Platform.isMacOS) {
        final old = File(p.join(root, 'vlc', 'VLC.app', 'Contents', 'MacOS', 'lib', 'libvlc.dylib'));
        if (old.existsSync()) return p.dirname(old.path);
      }
    }
    return null;
  }

  static String pluginDirFor(String libDir) {
    if (kIsWeb) return libDir;
    final plugins = p.join(libDir, 'plugins');
    if (Directory(plugins).existsSync()) return plugins;
    return libDir;
  }
}
