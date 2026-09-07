import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import '../util/kotv_app_dirs.dart';

/// 桌面 libmpv 诊断：mpv 日志落盘 + 起播状态快照。
///
/// 用途：Win7 等机器「播放中、缓冲在涨、time-pos 不动，点暂停/seek 才起播」
/// 这类问题，Dart 侧只能看到 `pause=no`，看不到 AO/VO/解码是否真的启动。
/// 这里把 libmpv 自己的日志（AO/VO 初始化、`IAudioClient_Start` 失败、
/// `Set property: pause` 等）写到 `{Root}/data/log/kotv-mpv.log`，
/// 并在 open 后定点读取 `pause / paused-for-cache / core-idle / time-pos /
/// current-ao / current-vo / hwdec-current` 等属性，配合用户操作（暂停 / seek）
/// 前后的快照，精确定位卡在哪一层。
///
/// 日志级别默认 `info`（AO/VO 一行式信息，体积很小）；在「MPV 配置」里写
/// `kotv-log=debug`（或 `v` / `trace`）可加深，`kotv-log=no` 关闭落盘。
/// `kotv-*` 行只被本模块消费，不会作为 mpv 属性下发。
class KotvMpvDiag {
  KotvMpvDiag._();

  static const String fileName = 'kotv-mpv.log';
  static const int _maxBytes = 8 * 1024 * 1024;

  static File? _file;
  static Future<File?>? _opening;
  static bool _disabled = false;
  static int _written = 0;
  static final StringBuffer _pending = StringBuffer();
  static Timer? _flushTimer;
  static int _seq = 0;

  /// 从 mpv.conf 风格文本里取 `kotv-log=<level>`；未写则 `info`。
  /// 关闭（`kotv-log=no`）时返回 [MPVLogLevel.error]（media_kit 自身要吃 error）。
  static MPVLogLevel logLevelFromConf(String conf) {
    final v = _confValue(conf, 'kotv-log');
    switch (v) {
      case 'no':
      case 'off':
      case 'false':
      case 'none':
      case 'error':
        return MPVLogLevel.error;
      case 'warn':
        return MPVLogLevel.warn;
      case 'v':
      case 'verbose':
        return MPVLogLevel.v;
      case 'debug':
        return MPVLogLevel.debug;
      case 'trace':
        return MPVLogLevel.trace;
      default:
        return MPVLogLevel.info;
    }
  }

  /// `kotv-log=no` 时整体关闭（不订阅、不落盘）。
  static bool enabledFromConf(String conf) {
    switch (_confValue(conf, 'kotv-log')) {
      case 'no':
      case 'off':
      case 'false':
      case 'none':
        return false;
      default:
        return true;
    }
  }

  static String _confValue(String conf, String key) {
    for (final raw in conf.split(RegExp(r'[\r\n]+'))) {
      var line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final hash = line.indexOf('#');
      if (hash > 0) line = line.substring(0, hash).trim();
      final eq = line.indexOf('=');
      if (eq <= 0) continue;
      if (line.substring(0, eq).trim() != key) continue;
      return line.substring(eq + 1).trim().toLowerCase();
    }
    return '';
  }

  /// 订阅 [Player.stream.log] 并落盘；返回订阅供 dispose。
  static StreamSubscription<PlayerLog> attach(Player player, {String tag = 'mpv'}) {
    final id = ++_seq;
    note('[$tag#$id] attach player');
    return player.stream.log.listen((l) {
      _write('[$tag#$id] mpv/${l.level} ${l.prefix}: ${l.text}');
    });
  }

  /// Dart 侧动作记录（open / play / pause / seek / stop）。
  static void note(String text) => _write('[dart] $text');

  /// 只记 host，避免把带 token 的播放地址写进日志。
  static String hostOf(String url) {
    try {
      final u = Uri.parse(url);
      return u.host.isEmpty ? '?' : '${u.scheme}://${u.host}${u.path.endsWith('.m3u8') ? ' (hls)' : ''}';
    } catch (_) {
      return '?';
    }
  }

  static const List<String> _snapshotProps = [
    'pause',
    'paused-for-cache',
    'core-idle',
    'idle-active',
    'seeking',
    'eof-reached',
    'time-pos',
    'audio-pts',
    'duration',
    'demuxer-cache-duration',
    'demuxer-cache-idle',
    'cache-buffering-state',
    'current-ao',
    'audio-codec-name',
    'audio-params/samplerate',
    'audio-params/channel-count',
    'ao-mute',
    'current-vo',
    'hwdec-current',
    'video-codec',
    'video-out-params/dw',
    'video-out-params/dh',
    'estimated-vf-fps',
    'frame-drop-count',
    'vo-delayed-frame-count',
    'video-sync',
    'speed',
  ];

  /// 读一组关键属性写一行；[reason] 说明触发点（open+4s / before-pause 等）。
  static Future<void> snapshot(Player player, {required String reason}) async {
    if (_disabled) return;
    final platform = player.platform;
    if (platform == null) return;
    final parts = <String>[];
    for (final p in _snapshotProps) {
      try {
        final v = await (platform as dynamic)
            .getProperty(p, waitForInitialization: false) as String;
        parts.add('$p=${v.isEmpty ? '-' : v}');
      } catch (_) {
        parts.add('$p=!');
      }
    }
    _write('[snap:$reason] ${parts.join(' ')}');
  }

  /// open 后按 [delays] 定点快照（起播停滞时能看到 time-pos 是否在动）。
  static void scheduleOpenSnapshots(
    Player player, {
    List<Duration> delays = const [
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 10),
    ],
  }) {
    if (_disabled) return;
    for (final d in delays) {
      Timer(d, () {
        unawaited(snapshot(player, reason: 'open+${d.inSeconds}s'));
      });
    }
  }

  static void _write(String line) {
    if (_disabled) return;
    final ts = DateTime.now().toIso8601String();
    _pending.writeln('$ts $line');
    _flushTimer ??= Timer(const Duration(milliseconds: 400), _flush);
  }

  static Future<File?> _open() {
    if (_file != null) return Future.value(_file);
    return _opening ??= () async {
      try {
        final dir = await kotvLogDir();
        final f = File('${dir.path}${Platform.pathSeparator}$fileName');
        // 每次进程启动截断重写，避免无限增长。
        await f.writeAsString(
          '# KOTV libmpv diagnostics ${DateTime.now().toIso8601String()} '
          '${Platform.operatingSystem} ${Platform.operatingSystemVersion}\n',
          flush: true,
        );
        _written = 0;
        _file = f;
        debugPrint('KOTV mpv diag log: ${f.path}');
        return f;
      } catch (e) {
        debugPrint('KOTV mpv diag log unavailable: $e');
        _disabled = true;
        return null;
      }
    }();
  }

  static Future<void> _flush() async {
    _flushTimer = null;
    if (_pending.isEmpty) return;
    final chunk = _pending.toString();
    _pending.clear();
    final f = await _open();
    if (f == null) return;
    if (_written > _maxBytes) return;
    try {
      await f.writeAsString(chunk, mode: FileMode.append, flush: true);
      _written += chunk.length;
      if (_written > _maxBytes) {
        await f.writeAsString('# log size cap reached, stop writing\n',
            mode: FileMode.append, flush: true);
      }
    } catch (_) {}
  }
}
