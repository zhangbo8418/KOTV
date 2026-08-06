import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../api/kotv_api.dart';
import '../api/kotv_client_id.dart';

/// 探测并拉起本机 Go 引擎；随 UI 进程生命周期托管（窗口关闭即退出）。
class EngineLauncher {
  EngineLauncher();

  Process? _proc;
  Future<void>? _starting;
  bool _owned = false;
  bool _shuttingDown = false;
  bool _androidSpiderServiceStarted = false;
  String baseUrl = 'http://127.0.0.1:9978';
  DateTime _lastStartAttempt = DateTime.fromMillisecondsSinceEpoch(0);

  KotvApi client() => KotvApi(baseUrl: baseUrl);

  Future<bool> ensureReady({Duration timeout = const Duration(seconds: 30)}) async {
    // 尽早固化 clientId，后续 API / ui/poll 带同一身份。
    await kotvClientId();
    await _startOnce();

    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final bases = <String>{baseUrl, 'http://127.0.0.1:9978'};
      for (final base in bases) {
        final h = await _health(base);
        if (h == null || h['ok'] != true) continue;
        if (base != baseUrl) baseUrl = base;

        // 源已加载完成
        if (h['ready'] == true) return true;

        final source = '${h['source'] ?? ''}'.trim();
        final err = '${h['error'] ?? ''}';
        // 未配置点播源：引擎起来即可进 UI，勿空等 ready（会一直 false）
        if (source.isEmpty && _looksLikeNoSource(err)) {
          return true;
        }
        // 已配置源但还在拉仓/加载 jar：继续等到 ready 或超时
        break;
      }
      // 本进程托管的引擎若已退出，再拉一次；禁止在仍存活时 pkill 重开（竞态根因）。
      if (_owned && _proc != null && !await _procAlive(_proc!)) {
        _owned = false;
        _proc = null;
        await _startOnce();
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    // 超时：有源也先放行进壳，页面会显示「未就绪/重试」；无源同理。
    return _ping(baseUrl);
  }

  /// API 调用失败时调用：若引擎挂了则重启。
  /// [forceRestart] 只表示「务必确保可用」，**引擎已通时绝不误杀**。
  Future<bool> recoverIfNeeded({bool forceRestart = false}) async {
    if (_shuttingDown) return false;
    await _ensureAndroidSpiderService();
    if (await _ping(baseUrl)) return true;
    debugPrint('engine: recoverIfNeeded force=$forceRestart → restart');
    if (Platform.isAndroid) {
      await _startAndroidEngineService();
    } else {
      await _killOwnedQuietly();
    }
    return ensureReady(timeout: const Duration(seconds: 20));
  }

  /// 从后台回前台：先拉前景服务+ spider，再探 :9978；不通才重启。
  Future<bool> onAppResumed() async {
    if (_shuttingDown) return false;
    if (kIsWeb || Platform.isIOS) {
      return _ping(baseUrl);
    }
    debugPrint('engine: app resumed → health check');
    if (Platform.isAndroid) {
      await _startAndroidEngineService();
    }
    await _ensureAndroidSpiderService();
    if (await _ping(baseUrl)) {
      debugPrint('engine: still healthy after resume');
      return true;
    }
    debugPrint('engine: unhealthy after resume → restart');
    if (!Platform.isAndroid) {
      await _killOwnedQuietly();
    }
    return ensureReady(timeout: const Duration(seconds: 15));
  }

  Future<void> _startAndroidEngineService() async {
    if (!Platform.isAndroid) return;
    const ch = MethodChannel('kotv_android_spider');
    try {
      await ch.invokeMethod<void>('startEngine');
    } catch (e) {
      debugPrint('android engine service start failed: $e');
    }
  }

  Future<void> _killOwnedQuietly() async {
    final proc = _proc;
    if (proc == null || !_owned) {
      _proc = null;
      _owned = false;
      return;
    }
    _owned = false;
    _proc = null;
    try {
      proc.kill();
    } catch (_) {}
    try {
      await proc.exitCode.timeout(const Duration(milliseconds: 800));
    } catch (_) {}
  }

  Future<Map<String, dynamic>?> _health(String base) async {
    try {
      final h = await KotvApi(baseUrl: base).health().timeout(const Duration(seconds: 2));
      return Map<String, dynamic>.from(h);
    } catch (_) {
      return null;
    }
  }

  Future<bool> _ping(String base) async {
    final h = await _health(base);
    return h != null && h['ok'] == true;
  }

  static bool _looksLikeNoSource(String err) {
    if (err.trim().isEmpty) return true; // 源字段空且无错误：视为未配源
    return err.contains('未配置') || err.contains('点播源') || err.contains('请输入');
  }

  Future<bool> _procAlive(Process proc) async {
    // Android 无可靠 kill -0；统一用 exitCode 短超时探测。
    try {
      await proc.exitCode.timeout(const Duration(milliseconds: 1));
      return false; // 已退出
    } on TimeoutException {
      return true;
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

  /// Android：注入应用可写目录，供 Go paths.Root() 使用。
  Future<Map<String, String>> _androidEnv(Map<String, String> base) async {
    final env = Map<String, String>.from(base);
    const ch = MethodChannel('kotv_android_spider');
    try {
      final raw = await ch.invokeMethod<dynamic>('paths');
      if (raw is Map) {
        final cache = '${raw['cacheDir'] ?? ''}'.trim();
        final files = '${raw['filesDir'] ?? ''}'.trim();
        if (cache.isNotEmpty) {
          env['KOTV_CACHE_DIR'] = cache;
          env['KOTV_DATA_DIR'] = p.join(cache, 'KOTV');
        }
        if (files.isNotEmpty) {
          env['HOME'] = files;
        }
      }
    } catch (e) {
      debugPrint('android paths: $e');
    }
    return env;
  }

  /// Android 可执行候选：优先 nativeLibraryDir（可 exec），再拷到 codeCacheDir。
  /// 切勿拷到 files/support（Android 10+ 常 noexec，Process.start 会 Permission denied）。
  Future<List<String>> _androidEngineCandidates() async {
    const ch = MethodChannel('kotv_android_spider');
    final out = <String>[];
    String nativeSo = '';
    String codeCache = '';
    try {
      final raw = await ch.invokeMethod<dynamic>('paths');
      if (raw is Map) {
        final ep = '${raw['enginePath'] ?? ''}'.trim();
        final nativeDir = '${raw['nativeLibraryDir'] ?? ''}'.trim();
        codeCache = '${raw['codeCacheDir'] ?? ''}'.trim();
        if (ep.isNotEmpty && await File(ep).exists()) {
          nativeSo = ep;
        } else if (nativeDir.isNotEmpty) {
          final f = File(p.join(nativeDir, 'libkotv_engine.so'));
          if (await f.exists()) nativeSo = f.path;
        }
      }
    } catch (e) {
      debugPrint('android engine path: $e');
    }
    if (nativeSo.isNotEmpty) out.add(nativeSo);
    if (nativeSo.isNotEmpty && codeCache.isNotEmpty) {
      try {
        final dest = File(p.join(codeCache, 'libkotv_engine.so'));
        await File(nativeSo).copy(dest.path);
        try {
          await Process.run('chmod', ['+x', dest.path]);
        } catch (_) {}
        if (await dest.exists()) out.add(dest.path);
      } catch (e) {
        debugPrint('android engine copy to codeCache: $e');
      }
    }
    return out;
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

      // 1) 端口上已有健康引擎：直接复用，绝不要 pkill（多窗口/重试竞态根因）。
      if (await _ping('http://127.0.0.1:9978')) {
        baseUrl = 'http://127.0.0.1:9978';
        debugPrint('engine reuse: already healthy on 9978');
        return;
      }

      // 2) 本进程已 spawn、只是还没 ready：继续等，不要杀了重开。
      if (_owned && _proc != null && await _procAlive(_proc!)) {
        debugPrint('engine wait: owned pid=${_proc!.pid} still starting');
        return;
      }

      // 3) 清真正残留，但排除本进程刚拉起的 pid。Android 跳过桌面式 pkill。
      if (!Platform.isAndroid) {
        await _killStrayEngines(exceptPid: _proc?.pid);
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }

      // 清完后再探一次，避免和另一 UI 实例撞车。
      if (await _ping('http://127.0.0.1:9978')) {
        baseUrl = 'http://127.0.0.1:9978';
        debugPrint('engine reuse: healthy after stray cleanup');
        return;
      }

      var env = _runtimeEnv();
      if (Platform.isAndroid) {
        // Android：由前台服务托管引擎，避免进后台后 Dart 子进程被 OEM 杀掉。
        // 详情页用内存缓存看不出问题，一点 /api/v1/play 就 Connection closed。
        await _startAndroidEngineService();
        for (var i = 0; i < 40; i++) {
          if (await _ping('http://127.0.0.1:9978')) {
            baseUrl = 'http://127.0.0.1:9978';
            debugPrint('engine android: service healthy on 9978');
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        debugPrint('engine android: service failed to bring :9978 up; fallback Process.start');
        env = await _androidEnv(env);
        final candidates = await _androidEngineCandidates();
        if (candidates.isEmpty) {
          debugPrint('engine android: libkotv_engine.so not found in nativeLibraryDir');
          return;
        }
        for (final so in candidates) {
          try {
            debugPrint('engine start(android-fallback): $so');
            await _spawn(so, env);
            if (_proc != null && await _procAlive(_proc!)) return;
            debugPrint('engine android: process exited immediately after $so');
            _owned = false;
            _proc = null;
          } catch (e) {
            debugPrint('engine android spawn failed ($so): $e');
            _owned = false;
            _proc = null;
          }
        }
        return;
      }

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
    // 已标记启动过也要再探：后台杀进程后 :9979 会没了，不能靠 flag 跳过。
    if (_androidSpiderServiceStarted) {
      if (await _pingHttpOk('http://127.0.0.1:9979/health')) return;
      debugPrint('android spider service lost on 9979; restarting');
      _androidSpiderServiceStarted = false;
    }

    const ch = MethodChannel('kotv_android_spider');
    for (var i = 0; i < 6; i++) {
      try {
        // stop+start：Manager 若仍握着已死实例，单调 start 会直接 return。
        if (i == 0 || !_androidSpiderServiceStarted) {
          try {
            await ch.invokeMethod<void>('stop');
          } catch (_) {}
        }
        await ch.invokeMethod<void>('start');
      } catch (e) {
        debugPrint('android spider service start failed: $e');
      }
      // 确认 :9979 已监听（warm-up 失败也不应挡住 bind）
      if (await _pingHttpOk('http://127.0.0.1:9979/health')) {
        _androidSpiderServiceStarted = true;
        debugPrint('android spider service ready on 9979');
        return;
      }
      await Future<void>.delayed(Duration(milliseconds: 300 + i * 200));
    }
    debugPrint('android spider service: 9979 still down after retries');
  }

  Future<bool> _pingHttpOk(String url) async {
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
      try {
        final req = await client.getUrl(Uri.parse(url));
        final resp = await req.close().timeout(const Duration(seconds: 1));
        await resp.drain<void>();
        return resp.statusCode >= 200 && resp.statusCode < 300;
      } finally {
        client.close(force: true);
      }
    } catch (_) {
      return false;
    }
  }

  /// Win7 禁 PowerShell（会 WER 弹窗）；直接 `taskkill`/`cmd` 会闪黑框。
  /// 统一经 wscript //B + Run(...,0,True) 静默执行。
  Future<void> _winHiddenRun(String commandLine) async {
    Directory dir;
    try {
      dir = await getApplicationSupportDirectory();
    } catch (_) {
      dir = Directory.systemTemp;
    }
    final vbs = File(p.join(dir.path, 'kotv-hide-${DateTime.now().microsecondsSinceEpoch}.vbs'));
    final escaped = commandLine.replaceAll('"', '""');
    try {
      await vbs.writeAsString(
        'On Error Resume Next\n'
        'CreateObject("WScript.Shell").Run "$escaped", 0, True\n',
      );
      await Process.run('wscript.exe', ['//B', '//Nologo', vbs.path]);
    } catch (_) {
    } finally {
      try {
        await vbs.delete();
      } catch (_) {}
    }
  }

  void _winHiddenRunSync(String commandLine) {
    final vbs = File(p.join(Directory.systemTemp.path, 'kotv-hide-sync-$pid.vbs'));
    final escaped = commandLine.replaceAll('"', '""');
    try {
      vbs.writeAsStringSync(
        'On Error Resume Next\n'
        'CreateObject("WScript.Shell").Run "$escaped", 0, True\n',
      );
      Process.runSync('wscript.exe', ['//B', '//Nologo', vbs.path]);
    } catch (_) {
    } finally {
      try {
        vbs.deleteSync();
      } catch (_) {}
    }
  }

  /// WMI VBScript（Win7 可用）按命令行特征结束捆绑 Java/Python，无 PowerShell。
  static const _winKillStrayRuntimesVbs =
      'On Error Resume Next\n'
      'Set wmi = GetObject("winmgmts:\\\\.\\root\\cimv2")\n'
      'For Each p In wmi.ExecQuery("Select ProcessId,CommandLine from Win32_Process")\n'
      '  cl = LCase("" & p.CommandLine)\n'
      '  If InStr(cl, "spider-bridge.jar --serve") > 0 Or InStr(cl, "_kotv_runner.py") > 0 Then\n'
      '    p.Terminate\n'
      '  End If\n'
      'Next\n';

  Future<void> _winKillStrayRuntimes() async {
    Directory dir;
    try {
      dir = await getApplicationSupportDirectory();
    } catch (_) {
      dir = Directory.systemTemp;
    }
    final vbs = File(p.join(dir.path, 'kotv-kill-rt-${DateTime.now().microsecondsSinceEpoch}.vbs'));
    try {
      await vbs.writeAsString(_winKillStrayRuntimesVbs);
      await Process.run('wscript.exe', ['//B', '//Nologo', vbs.path]);
    } catch (_) {
    } finally {
      try {
        await vbs.delete();
      } catch (_) {}
    }
  }

  void _winKillStrayRuntimesSync() {
    final vbs = File(p.join(Directory.systemTemp.path, 'kotv-kill-rt-sync-$pid.vbs'));
    try {
      vbs.writeAsStringSync(_winKillStrayRuntimesVbs);
      Process.runSync('wscript.exe', ['//B', '//Nologo', vbs.path]);
    } catch (_) {
    } finally {
      try {
        vbs.deleteSync();
      } catch (_) {}
    }
  }

  Future<void> _killStrayEngines({int? exceptPid}) async {
    if (Platform.isAndroid) return;
    if (Platform.isWindows) {
      if (exceptPid != null && exceptPid > 0) {
        await _winHiddenRun('taskkill /F /T /IM kotv-engine.exe /FI "PID ne $exceptPid"');
      } else {
        await _winHiddenRun('taskkill /F /T /IM kotv-engine.exe');
      }
      await _killStrayRuntimes();
      return;
    }
    for (final pat in <String>[
      '/tmp/kotv-engine',
      'Contents/Resources/engine/kotv-engine',
      'Contents/MacOS/kotv-engine',
      'assets/engine/kotv-engine',
    ]) {
      try {
        final r = await Process.run('pgrep', ['-f', pat]);
        if (r.exitCode != 0) continue;
        for (final line in '${r.stdout}'.split(RegExp(r'\s+'))) {
          final id = int.tryParse(line.trim());
          if (id == null || id <= 0) continue;
          if (exceptPid != null && id == exceptPid) continue;
          Process.killPid(id, ProcessSignal.sigterm);
        }
      } catch (_) {}
    }
    await _killStrayRuntimes();
  }

  /// 清掉引擎死后残留的捆绑 Java bridge / Python runner（按命令行特征，避免误杀系统解释器）。
  Future<void> _killStrayRuntimes() async {
    if (Platform.isAndroid) return;
    if (Platform.isWindows) {
      await _winKillStrayRuntimes();
      return;
    }
    for (final pat in <String>['spider-bridge.jar --serve', '_kotv_runner.py']) {
      try {
        await Process.run('pkill', ['-f', pat]);
      } catch (_) {}
    }
  }

  Future<void> _killEngineTree(int enginePid) async {
    if (enginePid <= 0) return;
    if (Platform.isWindows) {
      await _winHiddenRun('taskkill /F /T /PID $enginePid');
      await _killStrayRuntimes();
      return;
    }
    Process.killPid(enginePid, ProcessSignal.sigkill);
    await _killStrayRuntimes();
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

    // 子进程（非 detached）：正常退出走 shutdown；UI 闪退时由看门狗清引擎+运行时。
    _proc = await Process.start(
      path,
      const [],
      environment: env,
      workingDirectory: p.dirname(path),
      mode: ProcessStartMode.normal,
    );
    _owned = true;
    _shuttingDown = false;
    final spawned = _proc!;
    // stdout 以前直接丢弃；JS console 曾误走 fmt.Println→stdout，现已改 stderr，
    // 两边都落到文件 + debugPrint，便于安卓/桌面排查。
    void pipe(List<int> chunk) {
      try {
        sink.add(chunk);
      } catch (_) {}
      try {
        final text = String.fromCharCodes(chunk);
        for (final line in text.split('\n')) {
          final t = line.trimRight();
          if (t.isNotEmpty) debugPrint('[engine] $t');
        }
      } catch (_) {}
    }
    spawned.stdout.listen(pipe);
    spawned.stderr.listen(pipe);
    // 引擎崩溃：UI 仍在则自动拉起（主动 shutdown 时不重启）。
    unawaited(spawned.exitCode.then((code) async {
      try {
        sink.writeln('exit code=$code');
        await sink.flush();
        await sink.close();
      } catch (_) {}
      if (_shuttingDown) return;
      if (!identical(_proc, spawned)) return;
      debugPrint('engine exited code=$code; auto-restart');
      _owned = false;
      _proc = null;
      try {
        await ensureReady(timeout: const Duration(seconds: 20));
      } catch (e) {
        debugPrint('engine auto-restart failed: $e');
      }
    }));
    sink.writeln('pid=${spawned.pid} owned=true');
    await _armOrphanWatchdog(spawned.pid, sink);
    await sink.flush();
    // 不要在这里 close sink；进程存活期间 stderr/stdout 仍要写入。
    await Future<void>.delayed(const Duration(milliseconds: 800));
  }

  /// UI 进程异常退出时杀掉引擎 + Java/Python，避免「窗口没了引擎还在」。
  /// Windows：不用 PowerShell（Win7 WER），用静默 wscript 轮询。
  Future<void> _armOrphanWatchdog(int enginePid, IOSink log) async {
    final uiPid = pid;
    if (Platform.isAndroid) {
      // Android 无可靠跨进程 pkill；引擎随 UI 进程生命周期托管即可。
      log.writeln('orphan-watchdog skipped(android) ui=$uiPid engine=$enginePid');
      return;
    }
    if (Platform.isWindows) {
      try {
        final support = await getApplicationSupportDirectory();
        final vbsPath = p.join(support.path, 'kotv-orphan-$enginePid.vbs');
        await File(vbsPath).writeAsString(
          'On Error Resume Next\n'
          'Set wmi = GetObject("winmgmts:\\\\.\\root\\cimv2")\n'
          'ui = $uiPid\n'
          'eng = $enginePid\n'
          'Do\n'
          '  Set q = wmi.ExecQuery("Select ProcessId from Win32_Process Where ProcessId=" & ui)\n'
          '  If q.Count = 0 Then\n'
          '    CreateObject("WScript.Shell").Run "taskkill /F /T /PID " & eng, 0, True\n'
          '    For Each p In wmi.ExecQuery("Select ProcessId,CommandLine from Win32_Process")\n'
          '      cl = LCase("" & p.CommandLine)\n'
          '      If InStr(cl, "spider-bridge.jar --serve") > 0 Or InStr(cl, "_kotv_runner.py") > 0 Then\n'
          '        p.Terminate\n'
          '      End If\n'
          '    Next\n'
          '    Exit Do\n'
          '  End If\n'
          '  WScript.Sleep 800\n'
          'Loop\n',
        );
        await Process.start(
          'wscript.exe',
          ['//B', '//Nologo', vbsPath],
          mode: ProcessStartMode.detached,
        );
        log.writeln('orphan-watchdog armed(wscript) ui=$uiPid engine=$enginePid');
      } catch (e) {
        log.writeln('orphan-watchdog failed(win): $e');
      }
      return;
    }
    // macOS / Linux：UI 没了 → TERM/KILL 引擎，再清捆绑运行时特征进程。
    try {
      await Process.start(
        '/bin/sh',
        [
          '-c',
          'UI=$uiPid; ENG=$enginePid; '
              'while kill -0 "\$UI" 2>/dev/null; do sleep 0.5; done; '
              'kill -TERM "\$ENG" 2>/dev/null; sleep 1; kill -KILL "\$ENG" 2>/dev/null; '
              'pkill -f "spider-bridge.jar --serve" 2>/dev/null; '
              'pkill -f "_kotv_runner.py" 2>/dev/null; true',
        ],
        mode: ProcessStartMode.detached,
      );
      log.writeln('orphan-watchdog armed ui=$uiPid engine=$enginePid');
    } catch (e) {
      log.writeln('orphan-watchdog failed: $e');
    }
  }

  bool get _isLocalEngine {
    final u = baseUrl.toLowerCase();
    return u.contains('127.0.0.1') || u.contains('localhost');
  }

  /// 窗口关闭 / 应用退出时调用：优雅停引擎（杀 Java/Python），超时再杀树。
  Future<void> shutdown() async {
    _shuttingDown = true;
    final proc = _proc;
    final owned = _owned;
    _proc = null;
    _owned = false;

    if (_isLocalEngine) {
      try {
        await KotvApi(baseUrl: baseUrl).requestShutdown();
      } catch (_) {}
    } else {
      // 远端：只离开会话，杀掉该用户 JVM/Py/JS，不关引擎。
      try {
        await KotvApi(baseUrl: baseUrl).sessionLeave();
      } catch (_) {}
    }

    if (proc != null && owned) {
      try {
        await proc.exitCode.timeout(const Duration(seconds: 4));
        await _killStrayRuntimes();
        return;
      } catch (_) {}
      await _killEngineTree(proc.pid);
      return;
    }

    // 未托管时不要乱杀：可能正被另一个 UI 实例使用。
    // 本机且无其它存活迹象时，仍清一次孤儿运行时。
    if (_isLocalEngine && proc == null) {
      await _killStrayRuntimes();
    }
  }

  /// 关程序专用：同步清掉本进程托管的引擎树，再 `exit`，避免残留与 await 挂死。
  void shutdownSync() {
    _shuttingDown = true;
    final proc = _proc;
    final owned = _owned;
    _proc = null;
    _owned = false;

    if (proc == null || !owned) {
      _killStrayRuntimesSync();
      return;
    }
    if (Platform.isWindows) {
      _winHiddenRunSync('taskkill /F /T /PID ${proc.pid}');
      _killStrayRuntimesSync();
      return;
    }
    try {
      proc.kill(ProcessSignal.sigterm);
    } catch (_) {}
    // 给优雅 Shutdown 留一点点时间，再清孤儿运行时。
    try {
      sleep(const Duration(milliseconds: 800));
    } catch (_) {}
    try {
      proc.kill(ProcessSignal.sigkill);
    } catch (_) {}
    _killStrayRuntimesSync();
  }

  void _killStrayRuntimesSync() {
    if (Platform.isWindows) {
      _winKillStrayRuntimesSync();
      return;
    }
    for (final pat in <String>['spider-bridge.jar --serve', '_kotv_runner.py']) {
      try {
        Process.runSync('pkill', ['-f', pat]);
      } catch (_) {}
    }
  }

  void dispose() {
    unawaited(shutdown());
  }
}
