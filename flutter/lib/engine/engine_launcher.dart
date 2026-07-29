import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../api/kotv_api.dart';

/// 探测并拉起本机 Go 引擎；随 UI 进程生命周期托管（窗口关闭即退出）。
class EngineLauncher {
  EngineLauncher();

  Process? _proc;
  Future<void>? _starting;
  bool _owned = false;
  bool _androidSpiderServiceStarted = false;
  String baseUrl = 'http://127.0.0.1:9978';
  DateTime _lastStartAttempt = DateTime.fromMillisecondsSinceEpoch(0);

  KotvApi client() => KotvApi(baseUrl: baseUrl);

  Future<bool> ensureReady({Duration timeout = const Duration(seconds: 30)}) async {
    await _startOnce();

    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await _pingReady(baseUrl)) return true;
      if (baseUrl != 'http://127.0.0.1:9978' && await _pingReady('http://127.0.0.1:9978')) {
        baseUrl = 'http://127.0.0.1:9978';
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    return _ping(baseUrl);
  }

  /// API 调用失败时调用：若引擎挂了则重启。
  Future<bool> recoverIfNeeded() async {
    if (await _ping(baseUrl)) return true;
    if (DateTime.now().difference(_lastStartAttempt) < const Duration(seconds: 2)) {
      await Future<void>.delayed(const Duration(seconds: 2));
      return _ping(baseUrl);
    }
    return ensureReady(timeout: const Duration(seconds: 20));
  }

  Future<bool> _ping(String base) async {
    try {
      final h = await KotvApi(baseUrl: base).health().timeout(const Duration(seconds: 2));
      return h['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _pingReady(String base) async {
    try {
      final h = await KotvApi(baseUrl: base).health().timeout(const Duration(seconds: 2));
      return h['ok'] == true && h['ready'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _startOnce() {
    _starting ??= _tryStartBundled().whenComplete(() => _starting = null);
    return _starting!;
  }

  Map<String, String> _runtimeEnv() {
    final env = Map<String, String>.from(Platform.environment);
    if ((env['KOTV_RUNTIME'] ?? '').trim().isNotEmpty) {
      return env;
    }
    final roots = <String>[];
    try {
      final exe = Platform.resolvedExecutable;
      final exeDir = p.dirname(exe);
      roots.add(p.normalize(p.join(exeDir, '..', 'Resources', 'runtime')));
      roots.add(p.normalize(p.join(exeDir, 'runtime')));
      roots.add(p.normalize(p.join(exeDir, '..', 'runtime')));
    } catch (_) {}
    roots.addAll([
      p.normalize(p.join(Directory.current.path, 'runtime')),
      p.normalize(p.join(Directory.current.path, '..', 'runtime')),
    ]);
    // 只认单层 runtime（含 jre 或 libvlc）；禁止依赖 runtime\runtime 嵌套布局。
    for (final root in roots) {
      if (Directory(root).existsSync() &&
          (Directory(p.join(root, 'jre')).existsSync() ||
              Directory(p.join(root, 'libvlc')).existsSync())) {
        env['KOTV_RUNTIME'] = root;
        break;
      }
    }
    return env;
  }

  List<String> _candidateBins(String exeName) {
    final out = <String>[];
    try {
      final exe = Platform.resolvedExecutable;
      out.add(p.normalize(p.join(p.dirname(exe), '..', 'Resources', 'engine', exeName)));
      out.add(p.normalize(p.join(p.dirname(exe), exeName)));
    } catch (_) {}
    out.addAll([
      p.join(Directory.current.path, exeName),
      p.join(Directory.current.path, '..', exeName),
      p.join(Directory.current.path, 'flutter', 'assets', 'engine', exeName),
      p.join(Directory.current.path, 'assets', 'engine', exeName),
    ]);
    return out;
  }

  Future<void> _tryStartBundled() async {
    if (kIsWeb || Platform.isIOS) return;
    _lastStartAttempt = DateTime.now();
    try {
      await _ensureAndroidSpiderService();
      // 已由本进程拉起且仍存活：直接复用
      if (_owned && _proc != null && await _ping('http://127.0.0.1:9978')) {
        baseUrl = 'http://127.0.0.1:9978';
        return;
      }

      // 清掉残留（旧 nohup / Debug），再由本进程作为父进程托管
      await _killStrayEngines();
      await Future<void>.delayed(const Duration(milliseconds: 250));

      final env = _runtimeEnv();
      final exeName = Platform.isWindows ? 'kotv-engine.exe' : 'kotv-engine';

      for (final c in _candidateBins(exeName)) {
        final f = File(c);
        if (await f.exists()) {
          debugPrint('engine start: $c runtime=${env['KOTV_RUNTIME']}');
          await _spawn(f.path, env);
          return;
        }
      }

      final data = await rootBundle.load('assets/engine/$exeName');
      final dir = await getApplicationSupportDirectory();
      final out = File(p.join(dir.path, exeName));
      await out.writeAsBytes(data.buffer.asUint8List(), flush: true);
      if (!Platform.isWindows) {
        await Process.run('chmod', ['+x', out.path]);
      }
      debugPrint('engine start(asset): ${out.path}');
      await _spawn(out.path, env);
    } catch (e, st) {
      debugPrint('engine start skipped: $e\n$st');
    }
  }

  Future<void> _ensureAndroidSpiderService() async {
    if (!Platform.isAndroid) return;
    if (_androidSpiderServiceStarted) return;
    _androidSpiderServiceStarted = true;

    const ch = MethodChannel('kotv_android_spider');
    try {
      await ch.invokeMethod<void>('start');
    } catch (e) {
      // ignore: 若 native 侧已在运行或 ROM 限制，后续由 go 引擎重试/失败兜底处理。
      debugPrint('android spider service start failed: $e');
    }
    // 给 native 线程一点时间完成 DexClassLoader / Chaquopy init。
    await Future<void>.delayed(const Duration(milliseconds: 450));
  }

  Future<void> _killStrayEngines() async {
    if (Platform.isWindows) {
      try {
        await Process.run('taskkill', ['/F', '/IM', 'kotv-engine.exe']);
      } catch (_) {}
      return;
    }
    for (final pat in <String>[
      '/tmp/kotv-engine',
      'Contents/Resources/engine/kotv-engine',
      'Contents/MacOS/kotv-engine',
      'assets/engine/kotv-engine',
    ]) {
      try {
        await Process.run('pkill', ['-f', pat]);
      } catch (_) {}
    }
  }

  Future<void> _spawn(String path, Map<String, String> env) async {
    final support = await getApplicationSupportDirectory();
    final logFile = File(p.join(support.path, 'kotv-engine-spawn.log'));
    final sink = logFile.openWrite(mode: FileMode.append);
    sink.writeln('${DateTime.now().toIso8601String()} spawn $path');

    final rt = (env['KOTV_RUNTIME'] ?? '').trim();
    if (rt.isNotEmpty) {
      try {
        await File('$path.runtime').writeAsString(rt);
      } catch (_) {}
    }

    // 子进程（非 detached）：正常退出走 shutdown；Win7 上 UI 原生闪退时父死子活，另起看门狗。
    _proc = await Process.start(
      path,
      const [],
      environment: env,
      workingDirectory: p.dirname(path),
      mode: ProcessStartMode.normal,
    );
    _owned = true;
    _proc!.stdout.listen((_) {});
    _proc!.stderr.listen((chunk) {
      try {
        sink.add(chunk);
      } catch (_) {}
    });
    sink.writeln('pid=${_proc!.pid} owned=true');
    await _armOrphanWatchdog(_proc!.pid, sink);
    await sink.flush();
    await sink.close();
    await Future<void>.delayed(const Duration(milliseconds: 800));
  }

  /// UI 进程异常退出时杀掉引擎，避免「窗口没了引擎还在」。
  Future<void> _armOrphanWatchdog(int enginePid, IOSink log) async {
    final uiPid = pid;
    if (Platform.isWindows) {
      try {
        await Process.start(
          'powershell.exe',
          [
            '-NoProfile',
            '-WindowStyle',
            'Hidden',
            '-Command',
            '\$ui=$uiPid; \$eng=$enginePid; '
                'while (Get-Process -Id \$ui -ErrorAction SilentlyContinue) { Start-Sleep -Milliseconds 500 }; '
                'Stop-Process -Id \$eng -Force -ErrorAction SilentlyContinue; '
                'Get-Process -Name kotv-engine -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue',
          ],
          mode: ProcessStartMode.detached,
        );
        log.writeln('orphan-watchdog armed ui=$uiPid engine=$enginePid');
      } catch (e) {
        log.writeln('orphan-watchdog failed: $e');
      }
      return;
    }
    // macOS / Linux：后台轮询父进程；UI 没了就杀引擎。
    try {
      await Process.start(
        '/bin/sh',
        [
          '-c',
          'UI=$uiPid; ENG=$enginePid; '
              'while kill -0 "\$UI" 2>/dev/null; do sleep 0.5; done; '
              'kill -TERM "\$ENG" 2>/dev/null; sleep 1; kill -KILL "\$ENG" 2>/dev/null; true',
        ],
        mode: ProcessStartMode.detached,
      );
      log.writeln('orphan-watchdog armed ui=$uiPid engine=$enginePid');
    } catch (e) {
      log.writeln('orphan-watchdog failed: $e');
    }
  }

  /// 窗口关闭 / 应用退出时调用：结束本进程托管的引擎。
  Future<void> shutdown() async {
    final proc = _proc;
    _proc = null;
    final owned = _owned;
    _owned = false;

    if (proc != null && owned) {
      try {
        proc.kill(ProcessSignal.sigterm);
      } catch (_) {}
      try {
        await proc.exitCode.timeout(const Duration(seconds: 2));
      } catch (_) {
        try {
          proc.kill(ProcessSignal.sigkill);
        } catch (_) {}
      }
      return;
    }

    // 兜底：清掉仍可能残留的引擎
    await _killStrayEngines();
  }

  void dispose() {
    unawaited(shutdown());
  }
}
