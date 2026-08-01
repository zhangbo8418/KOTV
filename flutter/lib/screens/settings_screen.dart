import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../engine/engine_launcher.dart';
import '../models/models.dart';
import '../player/kotv_platform.dart';
import '../providers.dart';
import '../remote/remote_bridge.dart';
import '../theme/kotv_palette.dart';
import '../util/runtime_info.dart';
import '../widgets/cast_flow.dart';
import '../widgets/chrome.dart';
import '../widgets/dialogs.dart';
import 'shell.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  Map<String, String> _s = {};
  Map<String, String> _runtime = {};
  List<Map<String, dynamic>> _parses = [];
  String _port = '9978';
  String _version = '0.1.0';
  String _status = '';
  String _pairCode = '';
  bool _loading = true;
  bool _busy = false;
  final _engineCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      _engineCtrl.text = p.getString('engine_base_url') ?? '';
    });
    _reload();
  }

  @override
  void dispose() {
    _engineCtrl.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    try {
      final data = await ref.read(apiProvider).getSettings();
      final map = Map<String, dynamic>.from((data['settings'] as Map?) ?? {});
      _s = {for (final e in map.entries) e.key: '${e.value ?? ''}'};
      final rt = Map<String, dynamic>.from((data['runtime'] as Map?) ?? {});
      _runtime = {for (final e in rt.entries) e.key: '${e.value ?? ''}'};
      _parses = ((data['parses'] as List?) ?? []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
      _port = '${data['port'] ?? '9978'}';
      _version = '${data['version'] ?? '0.1.0'}';
      _pairCode = '${data['pairCode'] ?? g('syncPairCode')}';
      await LocalHistory.setIncognito(g('incognito', 'false') == 'true');
    } catch (e) {
      _status = '$e';
    }
    if (mounted) setState(() => _loading = false);
  }

  String g(String k, [String d = '']) => _s[k]?.isNotEmpty == true ? _s[k]! : d;

  Future<void> _set(String key, String value, {String? msg}) async {
    try {
      final data = await ref.read(apiProvider).setSetting(key, value);
      final map = Map<String, dynamic>.from((data['settings'] as Map?) ?? {});
      setState(() {
        _s = {for (final e in map.entries) e.key: '${e.value ?? ''}'};
        _pairCode = '${data['pairCode'] ?? g('syncPairCode')}';
        _status = msg ?? '已保存';
      });
      if (key == 'incognito') {
        await LocalHistory.setIncognito(value == 'true');
      }
      ref.invalidate(settingsProvider);
      if (key == 'vod' ||
          key == 'theme' ||
          key.startsWith('wall') ||
          key == 'player' ||
          key.startsWith('player') ||
          key == 'preferredParse' ||
          key == 'adFilter' ||
          key == 'm3u8FilterConfig' ||
          key == 'danmaku' ||
          key == 'danmakuApi') {
        ref.invalidate(configProvider);
        ref.invalidate(homeProvider);
      }
    } catch (e) {
      setState(() => _status = '$e');
    }
  }

  Future<void> _setMany(Map<String, String> kv, {String? msg}) async {
    try {
      final data = await ref.read(apiProvider).setSettings(kv);
      final map = Map<String, dynamic>.from((data['settings'] as Map?) ?? {});
      setState(() {
        _s = {for (final e in map.entries) e.key: '${e.value ?? ''}'};
        _status = msg ?? '已保存';
      });
      ref.invalidate(settingsProvider);
      ref.invalidate(configProvider);
    } catch (e) {
      setState(() => _status = '$e');
    }
  }

  Future<void> _prompt(String title, String hint, String initial, Future<void> Function(String) onOK) async {
    final c = TextEditingController(text: initial);
    final p = KotvPalette.of(context);
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.dialogBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text(title, style: TextStyle(color: p.fg, fontWeight: FontWeight.w700)),
        content: SizedBox(
          width: 540,
          child: TextField(
            controller: c,
            autofocus: true,
            style: TextStyle(color: p.fg),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: TextStyle(color: p.muted),
              filled: true,
              fillColor: p.input,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('取消', style: TextStyle(color: p.muted))),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('确定')),
        ],
      ),
    );
    if (v != null) await onOK(v);
  }

  Future<void> _pick(String title, String key, List<(String, String)> options, {String? msg}) async {
    final v = await pickChoice(context, title: title, current: g(key), options: options);
    if (v != null) await _set(key, v, msg: msg);
  }

  Future<T?> _runTool<T>(String label, Future<T> Function() run) async {
    if (_busy) return null;
    setState(() {
      _busy = true;
      _status = '$label…';
    });
    try {
      return await run();
    } catch (e) {
      if (mounted) setState(() => _status = '$e');
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _ellipsize(String s, [int n = 28]) => s.length <= n ? s : '${s.substring(0, n)}…';

  String get _adMode {
    final on = g('adFilter', 'true');
    final cfg = g('m3u8FilterConfig');
    final enabled = on.isEmpty || on == 'true' || on == '1' || on == 'on';
    if (!enabled) return 'off';
    if (cfg.contains('"violentFilterModeFlag":true')) return 'violent';
    return 'on';
  }

  Future<void> _setAdMode(String mode) async {
    if (mode == 'off') {
      await _setMany({
        'adFilter': 'false',
        'm3u8FilterConfig': '{"tsNameLenExtend":1,"theExtinfBenchmarkN":5,"violentFilterModeFlag":false}',
      }, msg: '广告过滤已关闭');
    } else if (mode == 'violent') {
      await _setMany({
        'adFilter': 'true',
        'm3u8FilterConfig': '{"tsNameLenExtend":1,"theExtinfBenchmarkN":5,"violentFilterModeFlag":true}',
      }, msg: '已开启暴力过滤');
    } else {
      await _setMany({
        'adFilter': 'true',
        'm3u8FilterConfig': '{"tsNameLenExtend":1,"theExtinfBenchmarkN":5,"violentFilterModeFlag":false}',
      }, msg: '广告过滤已开启');
    }
  }

  Future<void> _pickAd() async {
    final v = await pickChoice(context, title: '广告过滤', current: _adMode, options: const [
      ('关闭', 'off'),
      ('开启', 'on'),
      ('暴力模式', 'violent'),
    ]);
    if (v != null) await _setAdMode(v);
  }

  Future<void> _checkUpdate() async {
    final data = await _runTool('检查更新中', () => ref.read(apiProvider).tools('checkUpdate'));
    if (data == null || !mounted) return;
    final msg = '${data['message'] ?? ''}';
    setState(() => _status = msg);
    showAppNews(context, msg.isEmpty ? '检查完成' : msg);
  }

  Future<void> _checkSpider() async {
    final data = await _runTool('检测爬虫中', () => ref.read(apiProvider).tools('checkSpider'));
    if (data == null || !mounted) return;
    final msg = '${data['message'] ?? ''}';
    setState(() => _status = msg);
    final results = ((data['results'] as List?) ?? []).whereType<Map>().toList();
    if (results.isEmpty) {
      showAppNews(context, msg);
      return;
    }
    final lines = results.take(20).map((e) {
      final ok = e['ok'] == true;
      return '${ok ? '✓' : '✗'} ${e['name'] ?? e['key']}${ok ? '' : ' — ${e['message']}'}';
    });
    showAppNews(context, '$msg\n\n${lines.join('\n')}');
  }

  Future<void> _clearCache() async {
    final choice = await pickChoice(context, title: '清理缓存', current: 'all', options: const [
      ('全部清理（推荐）', 'all'),
      ('仅 JS / Python', 'script'),
      ('仅 JAR', 'jar'),
      ('仅磁力下载', 'magnet'),
      ('仅日志', 'logs'),
      ('杂项（HTTP/EPG/字幕等）', 'other'),
    ]);
    if (choice == null || !mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF63248A),
        title: const Text('确认清理？', style: TextStyle(color: Colors.white)),
        content: Text(
          choice == 'all'
              ? '将清理 JS/PY、JAR、磁力下载、日志与杂项缓存。\n不会删除设置与观看历史。\n清理爬虫包后会自动重载点播源。'
              : (choice == 'script' || choice == 'jar')
                  ? '将清理所选爬虫缓存，不会删除设置与观看历史。\n清理后会自动重载点播源。'
                  : '将清理所选缓存，不会删除设置与观看历史。',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清理', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    final params = <String, dynamic>{
      'script': choice == 'all' || choice == 'script',
      'jar': choice == 'all' || choice == 'jar',
      'magnet': choice == 'all' || choice == 'magnet',
      'logs': choice == 'all' || choice == 'logs',
      'other': choice == 'all' || choice == 'other',
    };
    final data = await _runTool('正在清理缓存', () => ref.read(apiProvider).tools('clearCache', params));
    // 顺带清 Flutter 侧引擎启动日志
    try {
      final dir = await getApplicationSupportDirectory();
      final spawn = File('${dir.path}/kotv-engine-spawn.log');
      if (await spawn.exists()) await spawn.writeAsString('');
      await for (final f in dir.list()) {
        final name = f.path.split(Platform.pathSeparator).last;
        if (name.startsWith('kotv-orphan-') || name.startsWith('kotv-hide-') || name.startsWith('kotv-kill-rt-')) {
          try {
            await f.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
    if (data == null || !mounted) return;
    final msg = '${data['message'] ?? '清理完成'}';
    if (data['reloaded'] == true) {
      ref.invalidate(configProvider);
      ref.invalidate(homeProvider);
      ref.invalidate(settingsProvider);
    }
    setState(() => _status = msg);
    showAppNews(context, msg);
  }

  Future<void> _showPair() async {
    final code = _pairCode.isNotEmpty ? _pairCode : g('syncPairCode');
    showAppNews(context, '本机配对码: $code\n\n局域网设备同步时需输入此码\n遥控端口: $_port');
  }

  Future<void> _resetPair() async {
    final data = await _runTool('重置配对码', () => ref.read(apiProvider).tools('resetPair'));
    if (data == null || !mounted) return;
    setState(() {
      _pairCode = '${data['pairCode'] ?? ''}';
      _status = '${data['message'] ?? '已重置'}';
    });
  }

  Future<void> _syncSend(String type) async {
    final hostCtrl = TextEditingController();
    final pairCtrl = TextEditingController();
    final p = KotvPalette.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.dialogBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text(type == 'keep' ? '发送收藏到设备' : '发送历史到设备', style: TextStyle(color: p.fg)),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: hostCtrl,
                style: TextStyle(color: p.fg),
                decoration: InputDecoration(hintText: '192.168.1.100 或 IP:9978', hintStyle: TextStyle(color: p.muted)),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: pairCtrl,
                style: TextStyle(color: p.fg),
                decoration: InputDecoration(hintText: '对端配对码', hintStyle: TextStyle(color: p.muted)),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('取消', style: TextStyle(color: p.muted))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('发送')),
        ],
      ),
    );
    if (ok != true) return;
    final data = await _runTool('正在发送', () => ref.read(apiProvider).tools('syncSend', {
          'host': hostCtrl.text.trim(),
          'pair': pairCtrl.text.trim(),
          'type': type,
        }));
    if (data == null || !mounted) return;
    setState(() => _status = '${data['message'] ?? '已发送'}');
  }

  Future<void> _backupExport() async {
    final dir = await getApplicationDocumentsDirectory();
    final def = '${dir.path}${Platform.pathSeparator}kotv-backup.json.gz';
    await _prompt('备份导出路径', def, def, (path) async {
      final data = await _runTool('正在备份', () => ref.read(apiProvider).tools('backupExport', {'path': path}));
      if (data == null || !mounted) return;
      setState(() => _status = '${data['message'] ?? '备份已导出'} → $path');
      showAppNews(context, '备份已导出\n$path');
    });
  }

  Future<void> _backupImport() async {
    final dir = await getApplicationDocumentsDirectory();
    final def = '${dir.path}${Platform.pathSeparator}kotv-backup.json.gz';
    await _prompt('备份文件路径', def, def, (path) async {
      final data = await _runTool('正在恢复', () => ref.read(apiProvider).tools('backupImport', {'path': path}));
      if (data == null || !mounted) return;
      setState(() => _status = '${data['message'] ?? '备份已恢复'}');
      await _reload();
      ref.invalidate(configProvider);
      ref.invalidate(homeProvider);
      showAppNews(context, '${data['message'] ?? '备份已恢复'}');
    });
  }

  Future<void> _cast() async {
    final msg = await runKotvCast(
      context,
      ref.read(apiProvider),
      onStatus: (m) {
        if (mounted) setState(() => _status = m);
      },
    );
    if (msg != null && mounted) setState(() => _status = msg);
  }

  Future<void> _pickWall() async {
    final wall = g('wallMode', 'config');
    final v = await pickChoice(
      context,
      title: '选择壁纸',
      current: wall,
      options: const [
        ('极光紫', 'gradient'),
        ('配置墙纸', 'config'),
        ('网络图片', 'url'),
        ('本地文件', 'file'),
        ('深海蓝', 'builtin1'),
        ('绯霞玫', 'builtin2'),
        ('墨夜青', 'builtin3'),
      ],
    );
    if (v == null) return;
    if (v == 'url') {
      await _prompt('壁纸 URL', 'https://...', g('wallURL'), (u) async {
        await _setMany({'wallMode': 'url', 'wallURL': u}, msg: '壁纸 URL 已保存');
        await _reload();
      });
    } else if (v == 'file') {
      await _prompt('本地壁纸路径', '/path/to/image.jpg', g('wallFile'), (p) async {
        await _setMany({'wallMode': 'file', 'wallFile': p}, msg: '壁纸文件已保存');
        await _reload();
      });
    } else {
      await _set('wallMode', v, msg: '壁纸已切换');
    }
  }

  Future<void> _resetWall() async {
    await _set('wallMode', 'gradient', msg: '已重置为极光紫');
  }

  Future<void> _pickHome(List<SiteInfo> sites) async {
    await showSitePicker(
      context,
      ref,
      sites: sites,
      onSelect: (key) async {
        String name = key;
        for (final s in sites) {
          if (s.key == key) {
            name = s.name;
            break;
          }
        }
        ref.read(uiBusyProvider.notifier).state = '正在切换到 $name…';
        try {
          await ref.read(apiProvider).setHome(key);
          ref.invalidate(configProvider);
          ref.invalidate(homeProvider);
          ref.invalidate(settingsProvider);
          setState(() => _status = '已切换首页数据源：$name');
        } catch (e) {
          setState(() => _status = '切换失败: $e');
        } finally {
          ref.read(uiBusyProvider.notifier).state = null;
        }
      },
    );
  }

  Future<void> _showRuntime(EngineLauncher launcher, AsyncValue<Map<String, dynamic>> cfg) async {
    final buf = StringBuffer('KO影视 $_version\n引擎 ${launcher.baseUrl}\n遥控端口 $_port\n');
    buf.writeln('ready=${cfg.maybeWhen(data: (c) => c['ready'], orElse: () => false)}');
    for (final line in formatKotvRuntimeLines(_runtime)) {
      buf.writeln(line);
    }
    showAppNews(context, buf.toString());
  }

  @override
  Widget build(BuildContext context) {
    final cfg = ref.watch(configProvider);
    final homeName = cfg.maybeWhen(
      data: (c) {
        final sites = ((c['sites'] as List?) ?? []).whereType<Map>();
        for (final s in sites) {
          if (s['home'] == true) return '${s['name'] ?? s['key']}';
        }
        return '未选择';
      },
      orElse: () => '未选择',
    );
    final launcher = ref.watch(engineLauncherProvider);
    final sites = cfg.maybeWhen(
      data: (c) => ((c['sites'] as List?) ?? [])
          .whereType<Map>()
          .map((e) => SiteInfo.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      orElse: () => <SiteInfo>[],
    );

    final playerVal = g('player', kotvDefaultVodPlayer());
    final playerLabel = flutterPlayerLabel(playerVal.isEmpty ? kotvDefaultVodPlayer() : playerVal);
    final livePlayerVal = g('playerLive', kotvDefaultLivePlayer());
    final livePlayerLabel = flutterPlayerLabel(livePlayerVal.isEmpty ? kotvDefaultLivePlayer() : livePlayerVal);
    final speed = g('playerSpeed', '1.0');
    final scale = g('playerScale', 'default');
    final decode = g('playerDecode', 'auto');
    final danOn = g('danmaku', 'false') == 'true';
    final incognito = g('incognito', 'false') == 'true';
    final dmr = g('dlnaRenderer', 'false') == 'true';
    final parseName = g('preferredParse').isEmpty ? '自动' : g('preferredParse');
    final wall = g('wallMode', 'config');
    final theme = g('theme', 'dark');
    final ad = _adMode;
    final scaleLabel = {
          'default': '适应',
          'fill': '拉伸',
          'zoom': 'Zoom',
          '16:9': '16:9',
          '4:3': '4:3',
        }[scale] ??
        scale;
    final decodeLabel = {'auto': '自动', 'soft': '软解码', 'hard': '硬解码'}[decode] ?? decode;
    final adLabel = {'off': '关闭', 'on': '开启', 'violent': '暴力'}[ad] ?? ad;
    final themeLabel = {'dark': '深色', 'light': '浅色', 'system': '跟随系统'}[theme] ?? theme;

    return Column(
      children: [
        LibraryTopBar(
          onBack: () => goKotvPage(ref, KotvPage.video),
          onSearch: () => goKotvPage(ref, KotvPage.search),
          onProfile: () => goKotvPage(ref, KotvPage.profile),
          onNews: () => showAppNews(context, '同一局域网内浏览器打开\nhttp://<本机IP>:$_port'),
          title: '设置',
        ),
        if (_status.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: Builder(builder: (context) {
              final p = KotvPalette.of(context);
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: p.pillBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: p.pillBorder),
                ),
                child: Row(
                  children: [
                    if (_busy)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2, color: p.primary),
                        ),
                      ),
                    Expanded(child: Text(_status, style: TextStyle(color: p.muted, fontSize: 13))),
                    InkWell(onTap: () => setState(() => _status = ''), child: Icon(Icons.close, color: p.muted, size: 16)),
                  ],
                ),
              );
            }),
          ),
        Expanded(
          child: _loading
              ? Center(child: CircularProgressIndicator(color: KotvPalette.of(context).primary))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(24, 14, 24, 40),
                  children: [
                    KotvSettingsCard(children: [
                      KotvSettingsWideTile(label: '首页数据源', value: homeName, onTap: () => _pickHome(sites)),
                      KotvSettingsGrid(children: [
                        KotvSettingsCell(
                          label: '点播播放器',
                          value: playerLabel,
                          onTap: () => _pick('点播播放器', 'player', const [
                            ('内置 MPV（默认）', 'innie#mpv'),
                            ('内置 VLC', 'innie#vlc'),
                            ('外部 VLC', 'outie#vlc'),
                            ('外部 MPV', 'outie#mpv'),
                            ('IINA', 'outie#iina'),
                          ], msg: '点播播放器已切换'),
                        ),
                        KotvSettingsCell(
                          label: '直播播放器',
                          value: livePlayerLabel,
                          onTap: () => _pick(
                            '直播播放器',
                            'playerLive',
                            [
                              ('内置 MPV${!Platform.isWindows ? '（默认）' : ''}', 'innie#mpv'),
                              ('内置 VLC${Platform.isWindows ? '（默认）' : ''}', 'innie#vlc'),
                              ('外部 VLC', 'outie#vlc'),
                              ('外部 MPV', 'outie#mpv'),
                              ('IINA', 'outie#iina'),
                            ],
                            msg: '直播播放器已切换',
                          ),
                        ),
                        KotvSettingsCell(
                          label: '默认倍速',
                          value: '$speed 倍',
                          onTap: () => _pick('默认倍速', 'playerSpeed', const [
                            ('0.5 倍', '0.5'),
                            ('0.75 倍', '0.75'),
                            ('1.0 倍', '1.0'),
                            ('1.25 倍', '1.25'),
                            ('1.5 倍', '1.5'),
                            ('2.0 倍', '2.0'),
                          ]),
                        ),
                        KotvSettingsCell(
                          label: '画面比例',
                          value: scaleLabel,
                          onTap: () => _pick('画面比例', 'playerScale', const [
                            ('适应', 'default'),
                            ('拉伸', 'fill'),
                            ('Zoom', 'zoom'),
                            ('16:9', '16:9'),
                            ('4:3', '4:3'),
                          ]),
                        ),
                        KotvSettingsCell(
                          label: '默认解析器',
                          value: parseName,
                          onTap: () async {
                            final opts = <(String, String)>[('自动（默认）', '')];
                            for (final p in _parses) {
                              final n = '${p['name'] ?? ''}';
                              if (n.isNotEmpty) opts.add((n, n));
                            }
                            if (opts.length <= 1) {
                              showAppNews(context, '当前配置无解析器列表');
                              return;
                            }
                            await _pick('默认解析器', 'preferredParse', opts);
                          },
                        ),
                        KotvSettingsCell(label: '广告过滤', value: adLabel, onTap: _pickAd),
                        KotvSettingsCell(
                          label: '弹幕',
                          value: danOn ? '开启' : '关闭',
                          onTap: () => _set('danmaku', danOn ? 'false' : 'true', msg: danOn ? '弹幕已关闭' : '弹幕已开启'),
                        ),
                        KotvSettingsCell(
                          label: '无痕模式',
                          value: incognito ? '开启' : '关闭',
                          onTap: () => _set('incognito', incognito ? 'false' : 'true', msg: incognito ? '无痕已关闭' : '无痕已开启'),
                        ),
                        KotvSettingsCell(
                          label: '投屏接收',
                          value: dmr ? '开启' : '关闭',
                          onTap: () => _set('dlnaRenderer', dmr ? 'false' : 'true', msg: dmr ? '已关闭 DLNA 被投端' : '已开启 DLNA 被投端'),
                        ),
                        KotvSettingsCell(
                          label: 'Web 遥控',
                          value: ':$_port',
                          onTap: () => showAppNews(context, '同一局域网内浏览器打开\nhttp://<本机IP>:$_port'),
                        ),
                      ]),
                      KotvSettingsWideTile(
                        label: '解码方式',
                        value: decodeLabel,
                        onTap: () => _pick('解码方式', 'playerDecode', const [
                          ('自动（推荐）', 'auto'),
                          ('软解码', 'soft'),
                          ('硬解码', 'hard'),
                        ]),
                      ),
                    ]),
                    const KotvSettingsSectionTitle('UI设置'),
                    KotvSettingsCard(children: [
                      KotvSettingsGrid(children: [
                        KotvSettingsCell(
                          label: '选择主题',
                          value: themeLabel,
                          onTap: () => _pick('主题', 'theme', const [
                            ('深色', 'dark'),
                            ('浅色', 'light'),
                            ('跟随系统', 'system'),
                          ], msg: '主题已保存'),
                        ),
                        KotvSettingsCell(label: '换张壁纸', value: _wallLabel(wall), onTap: _pickWall),
                        KotvSettingsCell(label: '重置壁纸', onTap: _resetWall),
                      ]),
                    ]),
                    const KotvSettingsSectionTitle('播放设置'),
                    KotvSettingsCard(children: [
                      KotvSettingsGrid(children: [
                        KotvSettingsCell(
                          label: '点播源',
                          value: g('vod').isEmpty ? '未配置' : _ellipsize(g('vod'), 10),
                          onTap: () async {
                            await showAddVodDialog(context, ref);
                            await _reload();
                          },
                        ),
                        KotvSettingsCell(
                          label: '直播源',
                          value: g('live').isEmpty ? '未配置' : _ellipsize(g('live'), 10),
                          onTap: () async {
                            await showAddLiveDialog(context, ref);
                            await _reload();
                            setState(() => _status = '直播源已保存');
                          },
                        ),
                        KotvSettingsCell(
                          label: '代理',
                          value: g('proxy').isEmpty ? '未配置' : _ellipsize(g('proxy'), 10),
                          onTap: () => _prompt('代理', 'false# 或 true#http://127.0.0.1:7890', g('proxy'), (v) => _set('proxy', v, msg: '代理已更新')),
                        ),
                        KotvSettingsCell(
                          label: '弹幕 API',
                          value: g('danmakuApi').isEmpty ? '未配置' : '已配置',
                          onTap: () => _prompt('弹幕 API', 'https://...', g('danmakuApi'), (v) => _set('danmakuApi', v)),
                        ),
                        KotvSettingsCell(
                          label: 'Assrt Token',
                          value: g('assrtToken').isEmpty ? '未配置' : '已配置',
                          onTap: () => _prompt('Assrt Token', 'token', g('assrtToken'), (v) => _set('assrtToken', v)),
                        ),
                        KotvSettingsCell(
                          label: '更新地址',
                          value: g('updateUrl').isEmpty ? '未配置' : _ellipsize(g('updateUrl'), 10),
                          onTap: () => _prompt('更新地址', 'version.json URL', g('updateUrl'), (v) => _set('updateUrl', v)),
                        ),
                        KotvSettingsCell(label: '投屏', value: 'DLNA', onTap: _cast),
                        KotvSettingsCell(
                          label: '线路选择',
                          value: '多仓',
                          onTap: () async {
                            final switched = await showRepoPicker(context, ref);
                            if (switched) {
                              await _reload();
                              setState(() => _status = '线路已切换');
                            }
                          },
                        ),
                        KotvSettingsCell(
                          label: '引擎地址',
                          value: _ellipsize(launcher.baseUrl, 12),
                          onTap: () => _prompt('Engine Base URL', 'http://127.0.0.1:9978', _engineCtrl.text, (v) async {
                            _engineCtrl.text = v;
                            final p = await SharedPreferences.getInstance();
                            if (v.isEmpty) {
                              await p.remove('engine_base_url');
                            } else {
                              await p.setString('engine_base_url', v);
                              launcher.baseUrl = v;
                            }
                            ref.invalidate(engineReadyProvider);
                            setState(() => _status = '引擎地址已保存');
                          }),
                        ),
                      ]),
                    ]),
                    const KotvSettingsSectionTitle('隐私与同步'),
                    KotvSettingsCard(children: [
                      KotvSettingsGrid(columns: 4, children: [
                        KotvSettingsCell(label: '配对码', value: _pairCode.isEmpty ? '查看' : _pairCode, onTap: _showPair),
                        KotvSettingsCell(label: '重置配对码', onTap: _resetPair),
                        KotvSettingsCell(label: '发送历史', onTap: () => _syncSend('history')),
                        KotvSettingsCell(label: '发送收藏', onTap: () => _syncSend('keep')),
                      ]),
                    ]),
                    const KotvSettingsSectionTitle('更多设置'),
                    KotvSettingsCard(children: [
                      KotvSettingsGrid(columns: 4, children: [
                        KotvSettingsCell(label: '数据备份', onTap: _backupExport),
                        KotvSettingsCell(label: '恢复备份', onTap: _backupImport),
                        KotvSettingsCell(label: '清理缓存', onTap: _clearCache),
                        if (!Platform.isIOS) KotvSettingsCell(label: '检测爬虫', onTap: _checkSpider),
                        KotvSettingsCell(label: '检查更新', value: _version, onTap: _checkUpdate),
                        KotvSettingsCell(label: '运行时信息', onTap: () => _showRuntime(launcher, cfg)),
                        KotvSettingsCell(
                          label: '关于',
                          value: 'KO影视',
                          onTap: () => showAppNews(context, 'KO影视 Flutter $_version\n引擎端口 $_port'),
                        ),
                      ]),
                    ]),
                  ],
                ),
        ),
      ],
    );
  }

  String _wallLabel(String m) => kotvWallModeNames[m] ?? m;
}
