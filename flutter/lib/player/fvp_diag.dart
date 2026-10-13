import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../util/kotv_app_dirs.dart';
import 'kotv_platform.dart';

/// FVP / mdk 取证落盘：时钟对照 + **HTTP 跟跳/Cookie/HTML**（Win7 直播）。
///
/// 只读：不改 `avsync.audio`，不做 Dart Location 预跳。
///
/// **同步落盘**：Win7 卡在 `initialize` 时 Timer 冲不掉 → 每条立刻 append+flush。
///
/// 路径：
/// - 主：`{Root}/data/log/kotv-fvp-clock.log`
/// - Win 镜像：`%USERPROFILE%\Documents\KOTV\kotv-fvp-clock.log`
class KotvFvpDiag {
  KotvFvpDiag._();

  static const String fileName = 'kotv-fvp-clock.log';
  static const int _maxBytes = 4 * 1024 * 1024;

  static File? _file;
  static File? _mirror;
  static bool _disabled = false;
  static bool _pathPrinted = false;
  static int _written = 0;

  static String get platformTag {
    if (kotvIsAndroid()) return 'android';
    if (kotvIsIOS()) return 'ios';
    if (kotvIsWindows()) {
      return kotvIsWindows7() ? 'win7' : 'windows';
    }
    if (!kIsWeb && Platform.isMacOS) return 'macos';
    if (!kIsWeb && Platform.isLinux) return 'linux';
    return 'other';
  }

  /// 只记 host，避免带 token 的播放地址进日志。
  static String hostOf(String url) {
    try {
      final u = Uri.parse(url);
      return u.host.isEmpty ? '?' : '${u.scheme}://${u.host}';
    } catch (_) {
      return '?';
    }
  }

  static void note(String text) {
    if (_disabled) return;
    final safe = text.replaceAll('\n', ' ');
    final full =
        '${DateTime.now().toIso8601String()} [$platformTag] $safe\n';
    debugPrint('KOTV FVP $safe');
    _ensureFiles();
    _appendSync(full);
  }

  /// 起播后定点脉冲（辅助）；Win7 卡死时可能不跑，主路径靠 listener 采样。
  static void scheduleClockPulses(void Function(String tag) sample) {
    for (final sec in const [1, 2, 3, 4, 5, 7, 10, 15, 20, 25, 30, 35, 40]) {
      unawaited(Future<void>.delayed(Duration(seconds: sec), () {
        try {
          sample('clock+${sec}s');
        } catch (_) {}
      }));
    }
  }

  static void _ensureFiles() {
    if (_file != null || _disabled) return;
    try {
      final dir = kotvLogDirSync();
      _file = File(p.join(dir.path, fileName));
      if (!_file!.existsSync()) {
        _file!.writeAsStringSync(
          '# KOTV FVP clock ${DateTime.now().toIso8601String()} '
          'os=$platformTag ${Platform.operatingSystemVersion}\n',
          flush: true,
        );
      }
      _written = _file!.lengthSync();
      if (kotvIsWindows()) {
        try {
          final home = Platform.environment['USERPROFILE']?.trim() ?? '';
          if (home.isNotEmpty) {
            final mirrorDir = Directory(p.join(home, 'Documents', 'KOTV'));
            if (!mirrorDir.existsSync()) {
              mirrorDir.createSync(recursive: true);
            }
            _mirror = File(p.join(mirrorDir.path, fileName));
            if (!_mirror!.existsSync()) {
              _mirror!.writeAsStringSync(
                '# mirror of ${_file!.path}\n',
                flush: true,
              );
            }
          }
        } catch (_) {}
      }
      if (!_pathPrinted) {
        _pathPrinted = true;
        final m = _mirror == null ? '' : ' mirror=${_mirror!.path}';
        debugPrint('KOTV FVP clock log: ${_file!.path}$m');
        _appendSync(
          '${DateTime.now().toIso8601String()} [$platformTag] '
          'log-path file=${_file!.path}$m\n',
        );
      }
    } catch (e) {
      debugPrint('KOTV FVP clock log unavailable: $e');
      _disabled = true;
    }
  }

  static void _appendSync(String chunk) {
    if (_disabled || chunk.isEmpty) return;
    try {
      if (_written + chunk.length > _maxBytes) return;
      final f = _file;
      if (f != null) {
        f.writeAsStringSync(chunk, mode: FileMode.append, flush: true);
        _written += chunk.length;
      }
      final m = _mirror;
      if (m != null) {
        m.writeAsStringSync(chunk, mode: FileMode.append, flush: true);
      }
    } catch (e) {
      debugPrint('KOTV FVP clock append fail: $e');
    }
  }
}
