import 'dart:async';
import '../util/kotv_io.dart';

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/kotv_api.dart';
import '../api/kotv_auth_token.dart';
import '../api/kotv_engine_url.dart';
import '../engine/engine_launcher.dart';
import '../models/models.dart';
import '../player/kotv_playback.dart';
import '../player/kotv_platform.dart';
import '../player/mpv_opts.dart';
import '../player/native_mpv_playback.dart';
import '../player/play_headers.dart';
import '../player/video_eq.dart';
import '../providers.dart';
import '../remote/remote_bridge.dart';
import '../theme/kotv_palette.dart';
import '../util/kotv_clear_ephemeral.dart';
import '../util/runtime_info.dart';
import '../widgets/auth_gate.dart';
import '../widgets/cast_flow.dart';
import '../widgets/chrome.dart';
import '../widgets/dialogs.dart';
import 'shell.dart';
import 'user_admin_screen.dart';

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
  String _remoteUser = '';
  String _vodDesc = '';
  String _liveDesc = '';
  bool _loading = true;
  bool _busy = false;
  /// 安卓：设备支持 Vulkan≥1.2 时才显示开关。
  bool _androidVulkanOk = false;
  final _engineCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) async {
      final draft = p.getString('engine_base_url_draft') ?? '';
      final effective = p.getString('engine_base_url') ?? '';
      _engineCtrl.text = draft.isNotEmpty ? draft : effective;
      _remoteUser = p.getString('remote_username') ?? '';
      if (mounted) setState(() {});
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
      _vodDesc = '${data['vodDesc'] ?? ''}';
      _liveDesc = '${data['liveDesc'] ?? ''}';
      await LocalHistory.setIncognito(g('incognito', 'false') == 'true');
      kotvApplyPlayUaSetting(g('ua'));
      if (kotvIsAndroid()) {
        _androidVulkanOk = await NativeMpvPlayback.isVulkanAvailable();
      }
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
        // 合并而非整表替换：避免 API 白名单漏键时把刚写入的值冲掉
        _s = {
          ..._s,
          for (final e in map.entries) e.key: '${e.value ?? ''}',
          key: value,
        };
        _pairCode = '${data['pairCode'] ?? g('syncPairCode')}';
        _status = msg ?? '已保存';
      });
      if (key == 'ua') {
        kotvApplyPlayUaSetting(value);
      }
      if (key == 'incognito') {
        await LocalHistory.setIncognito(value == 'true');
      }
      ref.invalidate(settingsProvider);
      if (key == 'vod' ||
          key == 'theme' ||
          key.startsWith('wall') ||
          key == 'player' ||
          key == 'ua' ||
          key.startsWith('player') ||
          key.startsWith('mpv') ||
          key == 'preferredParse' ||
          key == 'adFilter' ||
          key == 'm3u8FilterConfig' ||
          key == 'danmaku' ||
          key == 'danmakuApi' ||
          key == 'danmakuSize' ||
          key == 'danmakuOpacity' ||
          key == 'danmakuRows') {
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
        _s = {
          ..._s,
          for (final e in map.entries) e.key: '${e.value ?? ''}',
          ...kv,
        };
        _status = msg ?? '已保存';
      });
      ref.invalidate(settingsProvider);
      ref.invalidate(configProvider);
    } catch (e) {
      setState(() => _status = '$e');
    }
  }

  Future<void> _prompt(
    String title,
    String hint,
    String initial,
    Future<void> Function(String) onOK, {
    int maxLines = 1,
  }) async {
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
            maxLines: maxLines,
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

  /// 播放器二级设置：底部弹层，内嵌开关 / 滑块 / 入口。
  Future<void> _showPlayerSubSheet({
    required String title,
    required List<Widget> Function(StateSetter setSheet) buildChildren,
  }) async {
    final p = KotvPalette.of(context);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            final h = MediaQuery.sizeOf(ctx).height * 0.72;
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Material(
                  color: p.dialogBg,
                  borderRadius: BorderRadius.circular(16),
                  clipBehavior: Clip.antiAlias,
                  child: SizedBox(
                    height: h,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  title,
                                  style: TextStyle(color: p.fg, fontSize: 17, fontWeight: FontWeight.w700),
                                ),
                              ),
                              IconButton(
                                onPressed: () => Navigator.pop(ctx),
                                icon: Icon(Icons.close, color: p.muted),
                              ),
                            ],
                          ),
                        ),
                        Divider(height: 1, color: p.fg.withOpacity(0.08)),
                        Expanded(
                          child: ListView(
                            padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
                            children: buildChildren(setSheet),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
    if (mounted) setState(() {});
  }

  Widget _sheetToggle({
    required String label,
    required bool value,
    required Future<void> Function(bool next) onChanged,
    String? subtitle,
  }) {
    final p = KotvPalette.of(context);
    return ListTile(
      title: Text(label, style: TextStyle(color: p.fg, fontSize: 15, fontWeight: FontWeight.w500)),
      subtitle: subtitle == null
          ? null
          : Text(subtitle, style: TextStyle(color: p.muted, fontSize: 12)),
      trailing: Switch.adaptive(
        value: value,
        onChanged: (v) => unawaited(onChanged(v)),
      ),
    );
  }

  Widget _sheetNav({
    required String label,
    required String value,
    required VoidCallback onTap,
  }) {
    final p = KotvPalette.of(context);
    return ListTile(
      title: Text(label, style: TextStyle(color: p.fg, fontSize: 15, fontWeight: FontWeight.w500)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 140),
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: p.muted, fontSize: 14),
            ),
          ),
          Icon(Icons.chevron_right, color: p.muted.withOpacity(0.7)),
        ],
      ),
      onTap: onTap,
    );
  }

  Widget _sheetSlider({
    required String label,
    required double value,
    required double min,
    required double max,
    int divisions = 20,
    String Function(double)? format,
    required Future<void> Function(double) onCommit,
    void Function(double)? onChanging,
  }) {
    final p = KotvPalette.of(context);
    final fmt = format ?? ((v) => v.toStringAsFixed(v == v.roundToDouble() ? 0 : 1));
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(label, style: TextStyle(color: p.fg, fontSize: 14, fontWeight: FontWeight.w500)),
              ),
              Text(fmt(value), style: TextStyle(color: p.muted, fontSize: 13)),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              label: fmt(value),
              onChanged: onChanging,
              onChangeEnd: (v) => unawaited(onCommit(v)),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openExoSheet() async {
    await _showPlayerSubSheet(
      title: 'Exo 设置',
      buildChildren: (setSheet) {
        final exoDiskCache = kotvSettingsFlag(g('exoDiskCache', 'false'), def: false);
        final exoAdblock = kotvSettingsFlag(g('exoAdblock', 'true'), def: true);
        final exoTunneling = kotvSettingsFlag(g('exoTunneling', 'false'), def: false);
        final exoPreferAac = kotvSettingsFlag(g('exoPreferAac', 'false'), def: false);
        final exoSkipSilence = kotvSettingsFlag(g('exoSkipSilence', 'false'), def: false);
        final exoSoftAudioPrefer = kotvSettingsFlag(g('exoSoftAudioPrefer', 'true'), def: true);
        final exoSoftVideoPrefer = kotvSettingsFlag(g('exoSoftVideoPrefer', 'true'), def: true);
        final exoBuffer = (int.tryParse(g('exoBuffer', '1')) ?? 1).clamp(1, 10).toDouble();
        final exoPreload = (int.tryParse(g('exoDiskPreloadMs', '10000')) ?? 10000).clamp(0, 120000).toDouble();
        final exoPreloadThreads = (int.tryParse(g('exoDiskPreloadThreads', '2')) ?? 2).clamp(1, 10).toDouble();
        final exoPreloadSizeMb = (int.tryParse(g('exoDiskPreloadSizeMb', '256')) ?? 256).clamp(128, 4096).toDouble();
        final exoLibass = kotvSettingsFlag(g('exoLibass', 'true'), def: true);
        final exoSecondary = g('exoSecondarySubtitle', 'off').trim().toLowerCase();
        final exoSecondaryOn = exoSecondary != 'off';
        final exoDolby = int.tryParse(g('exoDolbyVision', '0')) ?? 0;
        final exoDolbyLabel = switch (exoDolby) {
          1 => '假定支持',
          2 => '假定不支持',
          _ => '自动',
        };
        final langs = g('exoPreferredTextLangs').trim();
        return [
          _sheetToggle(
            label: '磁盘缓存',
            value: exoDiskCache,
            onChanged: (v) async {
              await _set('exoDiskCache', v ? 'true' : 'false', msg: v ? '已开启 Exo 磁盘缓存' : '已关闭 Exo 磁盘缓存');
              setSheet(() {});
            },
          ),
          _sheetSlider(
            label: '磁盘预读',
            value: exoPreload,
            min: 0,
            max: 120000,
            divisions: 60,
            format: (v) => '${v.round()} ms',
            onChanging: (v) => setSheet(() => _s['exoDiskPreloadMs'] = '${v.round()}'),
            onCommit: (v) => _set('exoDiskPreloadMs', '${v.round()}', msg: 'Exo 磁盘预读已更新'),
          ),
          _sheetSlider(
            label: '预读线程',
            value: exoPreloadThreads,
            min: 1,
            max: 10,
            divisions: 9,
            format: (v) => '${v.round()}',
            onChanging: (v) => setSheet(() => _s['exoDiskPreloadThreads'] = '${v.round()}'),
            onCommit: (v) => _set('exoDiskPreloadThreads', '${v.round()}'),
          ),
          _sheetSlider(
            label: '预读容量',
            value: exoPreloadSizeMb,
            min: 128,
            max: 4096,
            divisions: 31,
            format: (v) => '${v.round()} MB',
            onChanging: (v) => setSheet(() => _s['exoDiskPreloadSizeMb'] = '${v.round()}'),
            onCommit: (v) => _set('exoDiskPreloadSizeMb', '${v.round()}'),
          ),
          _sheetSlider(
            label: '内存缓冲倍率',
            value: exoBuffer,
            min: 1,
            max: 10,
            divisions: 9,
            format: (v) => '${v.round()}×',
            onChanging: (v) => setSheet(() => _s['exoBuffer'] = '${v.round()}'),
            onCommit: (v) => _set('exoBuffer', '${v.round()}', msg: 'Exo 缓冲倍率已更新'),
          ),
          _sheetToggle(
            label: 'HLS 去广告',
            value: exoAdblock,
            onChanged: (v) async {
              await _set('exoAdblock', v ? 'true' : 'false');
              setSheet(() {});
            },
          ),
          _sheetToggle(
            label: '隧道模式',
            subtitle: '仅 Surface 渲染',
            value: exoTunneling,
            onChanged: (v) async {
              await _set('exoTunneling', v ? 'true' : 'false', msg: '重启播放生效');
              setSheet(() {});
            },
          ),
          _sheetToggle(
            label: '优先 AAC',
            value: exoPreferAac,
            onChanged: (v) async {
              await _set('exoPreferAac', v ? 'true' : 'false');
              setSheet(() {});
            },
          ),
          _sheetToggle(
            label: '跳过静音段',
            value: exoSkipSilence,
            onChanged: (v) async {
              await _set('exoSkipSilence', v ? 'true' : 'false');
              setSheet(() {});
            },
          ),
          _sheetToggle(
            label: '软解优先音轨',
            value: exoSoftAudioPrefer,
            onChanged: (v) async {
              await _set('exoSoftAudioPrefer', v ? 'true' : 'false');
              setSheet(() {});
            },
          ),
          _sheetToggle(
            label: '软解优先视轨',
            value: exoSoftVideoPrefer,
            onChanged: (v) async {
              await _set('exoSoftVideoPrefer', v ? 'true' : 'false');
              setSheet(() {});
            },
          ),
          _sheetToggle(
            label: 'ASS 特效字幕',
            value: exoLibass,
            onChanged: (v) async {
              await _set('exoLibass', v ? 'true' : 'false', msg: '重启播放生效');
              setSheet(() {});
            },
          ),
          _sheetToggle(
            label: '双字幕（自动）',
            value: exoSecondaryOn,
            onChanged: (v) async {
              await _set('exoSecondarySubtitle', v ? 'auto' : 'off', msg: '重启播放生效');
              setSheet(() {});
            },
          ),
          _sheetNav(
            label: '杜比视界',
            value: exoDolbyLabel,
            onTap: () async {
              final next = (exoDolby + 1) % 3;
              await _set('exoDolbyVision', '$next', msg: '杜比视界策略已更新');
              setSheet(() {});
            },
          ),
          _sheetNav(
            label: '首选字幕语言',
            value: langs.isEmpty ? '默认' : langs,
            onTap: () async {
              await _prompt(
                '首选字幕语言',
                '逗号分隔，如 zh,zh-CN,en。空=默认。',
                langs,
                (v) => _set('exoPreferredTextLangs', v.trim(), msg: '首选字幕语言已更新'),
              );
              setSheet(() {});
            },
          ),
        ];
      },
    );
  }

  Future<void> _openMpvSheet({
    required bool showGpuNext,
    required bool showVulkan,
    required bool showTls,
  }) async {
    await _showPlayerSubSheet(
      title: 'MPV 设置',
      buildChildren: (setSheet) {
        final mpvGpuNext = g('mpvGpuNext', 'false') == 'true';
        final mpvVulkan = g('mpvVulkan', 'false') == 'true';
        final mpvTlsVerify = kotvSettingsFlag(g('mpvTlsVerify', 'true'), def: true);
        final mpvDiskCache = kotvSettingsFlag(g('mpvDiskCache', 'false'), def: false);
        final conf = g('mpvConf').trim();
        return [
          if (showGpuNext)
            _sheetToggle(
              label: 'gpu-next',
              value: mpvGpuNext,
              onChanged: (v) async {
                await _set('mpvGpuNext', v ? 'true' : 'false', msg: '重启播放生效');
                setSheet(() {});
              },
            ),
          if (showVulkan)
            _sheetToggle(
              label: 'Vulkan',
              value: mpvVulkan,
              onChanged: (v) async {
                await _set('mpvVulkan', v ? 'true' : 'false', msg: '重启播放生效');
                setSheet(() {});
              },
            ),
          if (showTls)
            _sheetToggle(
              label: '校验证书 (TLS)',
              value: mpvTlsVerify,
              onChanged: (v) async {
                await _set('mpvTlsVerify', v ? 'true' : 'false', msg: '重启播放生效');
                setSheet(() {});
              },
            ),
          _sheetToggle(
            label: '磁盘缓存',
            value: mpvDiskCache,
            onChanged: (v) async {
              await _set('mpvDiskCache', v ? 'true' : 'false', msg: '重启播放生效');
              setSheet(() {});
            },
          ),
          _sheetNav(
            label: 'mpv.conf',
            value: conf.isEmpty ? '未配置' : _ellipsize(conf.replaceAll('\n', ' '), 18),
            onTap: () async {
              await _prompt(
                'MPV 配置（mpv.conf）',
                '桌面诊断：kotv-log=debug 加深 libmpv 日志；kotv-log=no 关闭。',
                g('mpvConf'),
                (v) async {
                  final conflicts = KotvMpvOpts.findConfConflicts(v);
                  final msg = conflicts.isEmpty
                      ? 'MPV 配置已保存'
                      : '已保存；下列键由设置/引擎托管将被忽略：${conflicts.join(', ')}';
                  await _set('mpvConf', v, msg: msg);
                },
                maxLines: 12,
              );
              setSheet(() {});
            },
          ),
        ];
      },
    );
  }

  Future<void> _openVideoEqSheet() async {
    await _showPlayerSubSheet(
      title: '画面调色',
      buildChildren: (setSheet) {
        var videoEq = g('videoEq', 'off').trim().toLowerCase();
        if (videoEq == 'on') videoEq = 'custom';
        final custom = videoEq == 'custom';
        double num(String key, [double def = 0]) => double.tryParse(g(key, '$def')) ?? def;
        Future<void> savePreset(String next) async {
          final label = KotvVideoEq.presetLabels[next] ?? next;
          await _set('videoEq', next, msg: next == 'off' ? '已关闭画面调色' : '画面调色：$label');
          setSheet(() {});
        }
        Widget chip(String id, String label) {
          final p = KotvPalette.of(context);
          final on = videoEq == id || (id == 'off' && (videoEq.isEmpty || videoEq == 'off'));
          return Padding(
            padding: const EdgeInsets.only(right: 8, bottom: 8),
            child: ChoiceChip(
              label: Text(label),
              selected: on,
              onSelected: (_) => unawaited(savePreset(id)),
              selectedColor: p.primary.withOpacity(0.35),
              labelStyle: TextStyle(color: p.fg, fontSize: 13),
            ),
          );
        }
        return [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Wrap(
              children: [
                for (final e in KotvVideoEq.presetLabels.entries) chip(e.key, e.value),
              ],
            ),
          ),
          if (custom) ...[
            _sheetSlider(
              label: '亮度',
              value: num('videoBrightness'),
              min: -100,
              max: 100,
              divisions: 40,
              format: (v) => '${v.round()}',
              onChanging: (v) => setSheet(() => _s['videoBrightness'] = '${v.round()}'),
              onCommit: (v) => _set('videoBrightness', '${v.round()}'),
            ),
            _sheetSlider(
              label: '对比度',
              value: num('videoContrast'),
              min: -100,
              max: 100,
              divisions: 40,
              format: (v) => '${v.round()}',
              onChanging: (v) => setSheet(() => _s['videoContrast'] = '${v.round()}'),
              onCommit: (v) => _set('videoContrast', '${v.round()}'),
            ),
            _sheetSlider(
              label: '饱和度',
              value: num('videoSaturation'),
              min: -100,
              max: 100,
              divisions: 40,
              format: (v) => '${v.round()}',
              onChanging: (v) => setSheet(() => _s['videoSaturation'] = '${v.round()}'),
              onCommit: (v) => _set('videoSaturation', '${v.round()}'),
            ),
            _sheetSlider(
              label: '伽马',
              value: num('videoGamma'),
              min: -100,
              max: 100,
              divisions: 40,
              format: (v) => '${v.round()}',
              onChanging: (v) => setSheet(() => _s['videoGamma'] = '${v.round()}'),
              onCommit: (v) => _set('videoGamma', '${v.round()}'),
            ),
            _sheetSlider(
              label: '色相',
              value: num('videoHue'),
              min: -100,
              max: 100,
              divisions: 40,
              format: (v) => '${v.round()}',
              onChanging: (v) => setSheet(() => _s['videoHue'] = '${v.round()}'),
              onCommit: (v) => _set('videoHue', '${v.round()}'),
            ),
            _sheetSlider(
              label: '色温',
              value: num('videoTemperature'),
              min: -100,
              max: 100,
              divisions: 40,
              format: (v) => '${v.round()}',
              onChanging: (v) => setSheet(() => _s['videoTemperature'] = '${v.round()}'),
              onCommit: (v) => _set('videoTemperature', '${v.round()}'),
            ),
            _sheetSlider(
              label: '锐度',
              value: num('videoSharpness').clamp(0, 100),
              min: 0,
              max: 100,
              divisions: 20,
              format: (v) => '${v.round()}',
              onChanging: (v) => setSheet(() => _s['videoSharpness'] = '${v.round()}'),
              onCommit: (v) => _set('videoSharpness', '${v.round()}'),
            ),
            _sheetSlider(
              label: '阴影抬升',
              value: num('videoShadow'),
              min: -100,
              max: 100,
              divisions: 40,
              format: (v) => '${v.round()}',
              onChanging: (v) => setSheet(() => _s['videoShadow'] = '${v.round()}'),
              onCommit: (v) => _set('videoShadow', '${v.round()}'),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'Exo Surface/Texture 均走原生调色（隧道/HDR 下不可用）；锐度/阴影在 Exo 为近似实现，MPV/FVP 更完整。',
                style: TextStyle(color: KotvPalette.of(context).muted, fontSize: 12),
              ),
            ),
          ],
        ];
      },
    );
  }

  Future<void> _openAudioEqSheet() async {
    await _showPlayerSubSheet(
      title: '音频均衡',
      buildChildren: (setSheet) {
        final audioEq = g('audioEq', 'off').trim().toLowerCase();
        final bands = g('audioEqBands');
        double bandGain(String freq, [double def = 0]) {
          for (final part in bands.split(',')) {
            final kv = part.trim().split(':');
            if (kv.length == 2 && kv[0].trim() == freq) {
              return double.tryParse(kv[1].trim()) ?? def;
            }
          }
          return def;
        }
        Future<void> writeBands(Map<String, double> map) async {
          final s = map.entries.map((e) => '${e.key}:${e.value.round()}').join(',');
          await _set('audioEqBands', s);
          setSheet(() {});
        }
        const presetChips = <(String, String)>[
          ('off', '关闭'),
          ('natural', '自然'),
          ('voice', '人声'),
          ('cinema', '影院'),
          ('bass', '低音'),
          ('treble', '高音'),
          ('pop', '流行'),
          ('rock', '摇滚'),
          ('dance', '舞曲'),
          ('electronic', '电子'),
          ('hiphop', '嘻哈'),
          ('jazz', '爵士'),
          ('classical', '古典'),
          ('custom', '自定义'),
        ];
        final freqs = <String, double>{
          '80': bandGain('80'),
          '300': bandGain('300'),
          '1000': bandGain('1000'),
          '3000': bandGain('3000'),
          '8000': bandGain('8000'),
        };
        Widget chip(String id, String label) {
          final p = KotvPalette.of(context);
          final on = audioEq == id;
          return Padding(
            padding: const EdgeInsets.only(right: 8, bottom: 8),
            child: ChoiceChip(
              label: Text(label),
              selected: on,
              onSelected: (_) async {
                await _set('audioEq', id, msg: id == 'off' ? '已关闭音频均衡' : '音频均衡：$label');
                setSheet(() {});
              },
              selectedColor: p.primary.withOpacity(0.35),
              labelStyle: TextStyle(color: p.fg, fontSize: 13),
            ),
          );
        }
        final dialogue = kotvAudioDialogueFromSettings({'audioDialogue': g('audioDialogue', '0')}).toDouble();
        final channelMode = kotvAudioChannelModeFromSettings({'audioChannelMode': g('audioChannelMode', 'auto')});
        final channelLabel = switch (channelMode) {
          'stereo' => '立体声',
          'mono' => '单声道',
          'reverse' => '左右反转',
          _ => '自动',
        };
        return [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Wrap(children: [for (final e in presetChips) chip(e.$1, e.$2)]),
          ),
          _sheetSlider(
            label: '对白增强',
            value: dialogue,
            min: 0,
            max: 100,
            divisions: 20,
            format: (v) => v <= 0 ? '关' : '${v.round()}',
            onChanging: (v) => setSheet(() => _s['audioDialogue'] = '${v.round()}'),
            onCommit: (v) => _set('audioDialogue', '${v.round()}', msg: '对白增强已更新'),
          ),
          _sheetSlider(
            label: '声道平衡',
            value: (double.tryParse(g('audioBalance', '0')) ?? 0).clamp(-100.0, 100.0),
            min: -100,
            max: 100,
            divisions: 40,
            format: (v) {
              final n = v.round();
              if (n == 0) return '居中';
              return n < 0 ? '左 ${-n}' : '右 $n';
            },
            onChanging: (v) => setSheet(() => _s['audioBalance'] = '${v.round()}'),
            onCommit: (v) => _set('audioBalance', '${v.round()}', msg: '声道平衡已更新'),
          ),
          _sheetNav(
            label: '声道模式',
            value: channelLabel,
            onTap: () async {
              final picked = await pickChoice(context, title: '声道模式', current: channelMode, options: const [
                ('自动', 'auto'),
                ('立体声', 'stereo'),
                ('单声道', 'mono'),
                ('左右反转', 'reverse'),
              ]);
              if (picked == null) return;
              await _set('audioChannelMode', picked, msg: '声道模式已更新');
              setSheet(() {});
            },
          ),
          _sheetSlider(
            label: '音量稳定',
            value: (double.tryParse(g('audioStability', '0')) ?? 0).clamp(0, 100),
            min: 0,
            max: 100,
            divisions: 20,
            format: (v) => v <= 0 ? '关' : '${v.round()}',
            onChanging: (v) => setSheet(() => _s['audioStability'] = '${v.round()}'),
            onCommit: (v) => _set('audioStability', '${v.round()}'),
          ),
          _sheetSlider(
            label: '音量提升',
            value: (double.tryParse(g('audioBoost', '0')) ?? 0).clamp(0, 1200),
            min: 0,
            max: 1200,
            divisions: 24,
            format: (v) => v <= 0 ? '0' : '+${(v / 100).toStringAsFixed(1)} dB',
            onChanging: (v) => setSheet(() => _s['audioBoost'] = '${v.round()}'),
            onCommit: (v) => _set('audioBoost', '${v.round()}'),
          ),
          _sheetSlider(
            label: '前置衰减',
            value: (double.tryParse(g('audioPreamp', '0')) ?? 0).clamp(-1200, 0),
            min: -1200,
            max: 0,
            divisions: 24,
            format: (v) => v >= 0 ? '0' : '${(v / 100).toStringAsFixed(1)} dB',
            onChanging: (v) => setSheet(() => _s['audioPreamp'] = '${v.round()}'),
            onCommit: (v) => _set('audioPreamp', '${v.round()}'),
          ),
          _sheetToggle(
            label: '响度归一',
            value: kotvAudioLoudnessFromSettings({'audioLoudness': g('audioLoudness', 'false')}),
            onChanged: (v) async {
              await _set('audioLoudness', v ? 'true' : 'false', msg: v ? '响度归一已开启' : '响度归一已关闭');
              setSheet(() {});
            },
          ),
          _sheetSlider(
            label: '中置增益',
            value: (double.tryParse(g('audioCenterGain', '0')) ?? 0).clamp(0, 1200),
            min: 0,
            max: 1200,
            divisions: 24,
            format: (v) => v <= 0 ? '0' : '+${(v / 100).toStringAsFixed(1)} dB',
            onChanging: (v) => setSheet(() => _s['audioCenterGain'] = '${v.round()}'),
            onCommit: (v) => _set('audioCenterGain', '${v.round()}'),
          ),
          _sheetSlider(
            label: '音画偏移',
            value: (double.tryParse(g('audioOffsetMs', '0')) ?? 0).clamp(-10000, 10000),
            min: -10000,
            max: 10000,
            divisions: 200,
            format: (v) {
              final n = v.round();
              if (n == 0) return '0 ms';
              return n > 0 ? '声滞后 ${n} ms' : '声超前 ${-n} ms';
            },
            onChanging: (v) => setSheet(() => _s['audioOffsetMs'] = '${v.round()}'),
            onCommit: (v) => _set('audioOffsetMs', '${v.round()}', msg: '音画偏移已更新'),
          ),
          if (audioEq == 'custom') ...[
            for (final e in freqs.entries)
              _sheetSlider(
                label: '${e.key} Hz',
                value: e.value.clamp(-12, 12),
                min: -12,
                max: 12,
                divisions: 24,
                format: (v) => '${v.round()} dB',
                onChanging: (v) {
                  freqs[e.key] = v;
                  setSheet(() {
                    _s['audioEqBands'] =
                        freqs.entries.map((x) => '${x.key}:${x.value.round()}').join(',');
                  });
                },
                onCommit: (v) {
                  freqs[e.key] = v;
                  return writeBands(freqs);
                },
              ),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              '直通开启时均衡/对白/声道效果不生效。中置增益仅多声道有效；音画偏移各引擎均支持。',
              style: TextStyle(color: KotvPalette.of(context).muted, fontSize: 12),
            ),
          ),
        ];
      },
    );
  }

  Future<void> _openSubtitleSheet() async {
    await _showPlayerSubSheet(
      title: '字幕样式',
      buildChildren: (setSheet) {
        final scale = (double.tryParse(g('subtitleFontScale', '1.0')) ?? 1.0).clamp(0.5, 2.5);
        final pos = (double.tryParse(g('subtitlePos', '100')) ?? 100).clamp(0.0, 150.0);
        final border = (double.tryParse(g('subtitleBorderSize', '2')) ?? 2).clamp(0.0, 8.0);
        final color = g('subtitleColor', '#FFFFFF');
        final borderColor = g('subtitleBorderColor', '#000000');
        final styleMode = g('subtitleStyleMode', 'custom').trim().toLowerCase();
        final styleLabel = switch (styleMode) {
          'original' => '原样',
          'system' => '系统',
          _ => '自定义',
        };
        final edgeType = g('subtitleEdgeType', 'outline').trim().toLowerCase();
        final edgeLabel = switch (edgeType) {
          'none' => '无',
          'shadow' => '阴影',
          'raised' => '凸起',
          'depressed' => '凹陷',
          _ => '描边',
        };
        return [
          _sheetNav(
            label: '样式模式',
            value: styleLabel,
            onTap: () async {
              final picked = await pickChoice(context, title: '字幕样式模式', current: styleMode, options: const [
                ('原样（保留片源样式）', 'original'),
                ('系统字幕样式', 'system'),
                ('自定义', 'custom'),
              ]);
              if (picked == null) return;
              await _set('subtitleStyleMode', picked, msg: '字幕样式模式已更新');
              setSheet(() {});
            },
          ),
          _sheetNav(
            label: '描边类型',
            value: edgeLabel,
            onTap: () async {
              final picked = await pickChoice(context, title: '字幕描边类型', current: edgeType, options: const [
                ('无', 'none'),
                ('描边', 'outline'),
                ('阴影', 'shadow'),
                ('凸起', 'raised'),
                ('凹陷', 'depressed'),
              ]);
              if (picked == null) return;
              await _set('subtitleEdgeType', picked);
              setSheet(() {});
            },
          ),
          _sheetSlider(
            label: '字号倍率',
            value: scale,
            min: 0.5,
            max: 2.5,
            divisions: 20,
            format: (v) => v.toStringAsFixed(2),
            onChanging: (v) => setSheet(() => _s['subtitleFontScale'] = v.toStringAsFixed(2)),
            onCommit: (v) => _set('subtitleFontScale', v.toStringAsFixed(2), msg: '字幕字号已更新'),
          ),
          _sheetSlider(
            label: '垂直位置',
            value: pos,
            min: 0,
            max: 150,
            divisions: 30,
            format: (v) => '${v.round()}',
            onChanging: (v) => setSheet(() => _s['subtitlePos'] = '${v.round()}'),
            onCommit: (v) => _set('subtitlePos', '${v.round()}', msg: '字幕位置已更新'),
          ),
          _sheetSlider(
            label: '描边宽度',
            value: border,
            min: 0,
            max: 8,
            divisions: 16,
            format: (v) => v.toStringAsFixed(1),
            onChanging: (v) => setSheet(() => _s['subtitleBorderSize'] = v.toStringAsFixed(1)),
            onCommit: (v) => _set('subtitleBorderSize', v.toStringAsFixed(1), msg: '字幕描边已更新'),
          ),
          _sheetSlider(
            label: '正文透明度',
            value: (double.tryParse(g('subtitleTextOpacity', '100')) ?? 100).clamp(0, 100),
            min: 0,
            max: 100,
            divisions: 20,
            format: (v) => '${v.round()}%',
            onChanging: (v) => setSheet(() => _s['subtitleTextOpacity'] = '${v.round()}'),
            onCommit: (v) => _set('subtitleTextOpacity', '${v.round()}'),
          ),
          _sheetSlider(
            label: '背景透明度',
            value: (double.tryParse(g('subtitleBgOpacity', '100')) ?? 100).clamp(0, 100),
            min: 0,
            max: 100,
            divisions: 20,
            format: (v) => '${v.round()}%',
            onChanging: (v) => setSheet(() => _s['subtitleBgOpacity'] = '${v.round()}'),
            onCommit: (v) => _set('subtitleBgOpacity', '${v.round()}'),
          ),
          _sheetSlider(
            label: '描边透明度',
            value: (double.tryParse(g('subtitleEdgeOpacity', '100')) ?? 100).clamp(0, 100),
            min: 0,
            max: 100,
            divisions: 20,
            format: (v) => '${v.round()}%',
            onChanging: (v) => setSheet(() => _s['subtitleEdgeOpacity'] = '${v.round()}'),
            onCommit: (v) => _set('subtitleEdgeOpacity', '${v.round()}'),
          ),
          _sheetSlider(
            label: '时间偏移',
            value: (double.tryParse(g('subtitleOffsetMs', '0')) ?? 0).clamp(-300000, 300000),
            min: -300000,
            max: 300000,
            divisions: 120,
            format: (v) {
              final s = (v / 1000).round();
              if (s == 0) return '0 s';
              return s > 0 ? '+$s s' : '$s s';
            },
            onChanging: (v) => setSheet(() => _s['subtitleOffsetMs'] = '${v.round()}'),
            onCommit: (v) => _set('subtitleOffsetMs', '${v.round()}', msg: '字幕偏移已更新'),
          ),
          _sheetSlider(
            label: '副字幕位置',
            value: (double.tryParse(g('subtitleSecondaryPos', '0')) ?? 0).clamp(0.0, 150.0),
            min: 0,
            max: 150,
            divisions: 30,
            format: (v) => '${v.round()}',
            onChanging: (v) => setSheet(() => _s['subtitleSecondaryPos'] = '${v.round()}'),
            onCommit: (v) => _set('subtitleSecondaryPos', '${v.round()}', msg: '副字幕位置已更新'),
          ),
          _sheetNav(
            label: '字幕颜色',
            value: color,
            onTap: () async {
              final picked = await pickChoice(context, title: '字幕颜色', current: color, options: const [
                ('白色', '#FFFFFF'),
                ('黄色', '#FFFF00'),
                ('青色', '#00FFFF'),
                ('绿色', '#00FF00'),
                ('自定义…', '__custom__'),
              ]);
              if (picked == null) return;
              if (picked == '__custom__') {
                await _prompt('字幕颜色', '#FFFFFF', color, (v) => _set('subtitleColor', v.trim()));
              } else {
                await _set('subtitleColor', picked);
              }
              setSheet(() {});
            },
          ),
          _sheetNav(
            label: '描边颜色',
            value: borderColor,
            onTap: () async {
              final picked = await pickChoice(context, title: '描边颜色', current: borderColor, options: const [
                ('黑色', '#000000'),
                ('深灰', '#333333'),
                ('无描边色', '#00000000'),
                ('自定义…', '__custom__'),
              ]);
              if (picked == null) return;
              if (picked == '__custom__') {
                await _prompt('描边颜色', '#000000', borderColor, (v) => _set('subtitleBorderColor', v.trim()));
              } else {
                await _set('subtitleBorderColor', picked);
              }
              setSheet(() {});
            },
          ),
          _sheetNav(
            label: '字幕背景',
            value: g('subtitleBgColor', '#00000000'),
            onTap: () async {
              final cur = g('subtitleBgColor', '#00000000');
              final picked = await pickChoice(context, title: '字幕背景', current: cur, options: const [
                ('透明', '#00000000'),
                ('半透明黑', '#80000000'),
                ('深黑', '#CC000000'),
                ('自定义…', '__custom__'),
              ]);
              if (picked == null) return;
              if (picked == '__custom__') {
                await _prompt('字幕背景色', '#80000000', cur, (v) => _set('subtitleBgColor', v.trim()));
              } else {
                await _set('subtitleBgColor', picked);
              }
              setSheet(() {});
            },
          ),
        ];
      },
    );
  }

  Future<void> _openDanmakuSheet() async {
    await _showPlayerSubSheet(
      title: '弹幕设置',
      buildChildren: (setSheet) {
        final on = g('danmaku', 'false').toLowerCase() == 'true';
        final size = (double.tryParse(g('danmakuSize', '18')) ?? 18).clamp(12.0, 48.0);
        final opacity = (double.tryParse(g('danmakuOpacity', '85')) ?? 85).clamp(0.0, 100.0);
        final rows = (double.tryParse(g('danmakuRows', '6')) ?? 6).clamp(1.0, 16.0);
        final offset = (double.tryParse(g('danmakuOffsetMs', '0')) ?? 0).clamp(-10000.0, 10000.0);
        final maxOnScreen = (double.tryParse(g('danmakuMaxOnScreen', '150')) ?? 150).clamp(10.0, 500.0);
        final scrollArea = (double.tryParse(g('danmakuScrollArea', '50')) ?? 50).clamp(10.0, 100.0);
        bool flag(String key, [bool def = true]) {
          final v = g(key, def ? 'true' : 'false').toLowerCase();
          if (v == 'false' || v == '0' || v == 'off') return false;
          if (v == 'true' || v == '1' || v == 'on') return true;
          return def;
        }
        return [
          _sheetToggle(
            label: '开启弹幕',
            value: on,
            onChanged: (v) async {
              await _set('danmaku', v ? 'true' : 'false', msg: v ? '弹幕已开启' : '弹幕已关闭');
              setSheet(() {});
            },
          ),
          _sheetToggle(
            label: '加载弹幕',
            value: flag('danmakuLoad'),
            onChanged: (v) async {
              await _set('danmakuLoad', v ? 'true' : 'false');
              setSheet(() {});
            },
          ),
          _sheetToggle(
            label: '自动搜索弹幕',
            value: flag('danmakuAuto'),
            onChanged: (v) async {
              await _set('danmakuAuto', v ? 'true' : 'false');
              setSheet(() {});
            },
          ),
          _sheetToggle(
            label: '片源弹幕优先',
            value: flag('danmakuSpiderFirst'),
            onChanged: (v) async {
              await _set('danmakuSpiderFirst', v ? 'true' : 'false');
              setSheet(() {});
            },
          ),
          _sheetNav(
            label: '弹幕 API',
            value: g('danmakuApi').isEmpty ? '未配置' : '已配置',
            onTap: () async {
              await _prompt('弹幕 API', 'https://…?n={name}&e={episode}', g('danmakuApi'), (v) => _set('danmakuApi', v));
              setSheet(() {});
            },
          ),
          _sheetSlider(
            label: '字号',
            value: size,
            min: 12,
            max: 48,
            divisions: 36,
            format: (v) => '${v.round()}',
            onChanging: (v) => setSheet(() => _s['danmakuSize'] = '${v.round()}'),
            onCommit: (v) => _set('danmakuSize', '${v.round()}'),
          ),
          _sheetSlider(
            label: '透明度',
            value: opacity,
            min: 15,
            max: 100,
            divisions: 17,
            format: (v) => '${v.round()}%',
            onChanging: (v) => setSheet(() => _s['danmakuOpacity'] = '${v.round()}'),
            onCommit: (v) => _set('danmakuOpacity', '${v.round()}'),
          ),
          _sheetSlider(
            label: '行数',
            value: rows,
            min: 1,
            max: 16,
            divisions: 15,
            format: (v) => '${v.round()}',
            onChanging: (v) => setSheet(() => _s['danmakuRows'] = '${v.round()}'),
            onCommit: (v) => _set('danmakuRows', '${v.round()}'),
          ),
          _sheetSlider(
            label: '同屏上限',
            value: maxOnScreen,
            min: 10,
            max: 500,
            divisions: 49,
            format: (v) => '${v.round()}',
            onChanging: (v) => setSheet(() => _s['danmakuMaxOnScreen'] = '${v.round()}'),
            onCommit: (v) => _set('danmakuMaxOnScreen', '${v.round()}'),
          ),
          _sheetSlider(
            label: '滚动区域',
            value: scrollArea,
            min: 10,
            max: 100,
            divisions: 18,
            format: (v) => '${v.round()}%',
            onChanging: (v) => setSheet(() => _s['danmakuScrollArea'] = '${v.round()}'),
            onCommit: (v) => _set('danmakuScrollArea', '${v.round()}'),
          ),
          _sheetSlider(
            label: '时轴偏移',
            value: offset,
            min: -5000,
            max: 5000,
            divisions: 100,
            format: (v) => '${v.round()} ms',
            onChanging: (v) => setSheet(() => _s['danmakuOffsetMs'] = '${v.round()}'),
            onCommit: (v) => _set('danmakuOffsetMs', '${v.round()}'),
          ),
          _sheetToggle(
            label: '滚动弹幕',
            value: flag('danmakuShowScroll'),
            onChanged: (v) async {
              await _set('danmakuShowScroll', v ? 'true' : 'false');
              setSheet(() {});
            },
          ),
          _sheetToggle(
            label: '顶部弹幕',
            value: flag('danmakuShowTop'),
            onChanged: (v) async {
              await _set('danmakuShowTop', v ? 'true' : 'false');
              setSheet(() {});
            },
          ),
          _sheetToggle(
            label: '底部弹幕',
            value: flag('danmakuShowBottom'),
            onChanged: (v) async {
              await _set('danmakuShowBottom', v ? 'true' : 'false');
              setSheet(() {});
            },
          ),
          _sheetToggle(
            label: '逆向弹幕',
            value: flag('danmakuShowReverse'),
            onChanged: (v) async {
              await _set('danmakuShowReverse', v ? 'true' : 'false');
              setSheet(() {});
            },
          ),
          _sheetToggle(
            label: '粗体',
            value: flag('danmakuBold', false),
            onChanged: (v) async {
              await _set('danmakuBold', v ? 'true' : 'false');
              setSheet(() {});
            },
          ),
          _sheetSlider(
            label: '滚动时长',
            value: (double.tryParse(g('danmakuDurationMs', '8000')) ?? 8000).clamp(3000, 15000),
            min: 3000,
            max: 15000,
            divisions: 24,
            format: (v) => '${(v / 1000).toStringAsFixed(1)} s',
            onChanging: (v) => setSheet(() => _s['danmakuDurationMs'] = '${v.round()}'),
            onCommit: (v) => _set('danmakuDurationMs', '${v.round()}'),
          ),
          _sheetSlider(
            label: '行距',
            value: (double.tryParse(g('danmakuLineSpacing', '1.4')) ?? 1.4).clamp(1.0, 2.0),
            min: 1.0,
            max: 2.0,
            divisions: 10,
            format: (v) => v.toStringAsFixed(1),
            onChanging: (v) => setSheet(() => _s['danmakuLineSpacing'] = v.toStringAsFixed(1)),
            onCommit: (v) => _set('danmakuLineSpacing', v.toStringAsFixed(1)),
          ),
        ];
      },
    );
  }

  /// 播放 User-Agent：空=默认；输入 `c`/`o` 快捷填 Chrome / OkHttp。
  Future<void> _editUa() async {
    final c = TextEditingController(text: g('ua'));
    final p = KotvPalette.of(context);
    var append = true;
    void detect(String s) {
      if (append && s.toLowerCase() == 'c') {
        append = false;
        c.value = TextEditingValue(
          text: kotvChromePlayUA,
          selection: TextSelection.collapsed(offset: kotvChromePlayUA.length),
        );
      } else if (append && s.toLowerCase() == 'o') {
        append = false;
        c.value = TextEditingValue(
          text: kotvOkHttpPlayUA,
          selection: TextSelection.collapsed(offset: kotvOkHttpPlayUA.length),
        );
      } else if (s.length > 1) {
        append = false;
      } else if (s.isEmpty) {
        append = true;
      }
    }

    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.dialogBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text('User-Agent', style: TextStyle(color: p.fg, fontWeight: FontWeight.w700)),
        content: SizedBox(
          width: 540,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '留空使用默认。输入 c → Chrome，o → OkHttp。',
                style: TextStyle(color: p.muted, fontSize: 12),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: c,
                autofocus: true,
                maxLines: 3,
                style: TextStyle(color: p.fg),
                onChanged: detect,
                decoration: InputDecoration(
                  hintText: kotvDefaultPlayUA,
                  hintStyle: TextStyle(color: p.muted, fontSize: 12),
                  filled: true,
                  fillColor: p.input,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('取消', style: TextStyle(color: p.muted))),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('确定')),
        ],
      ),
    );
    c.dispose();
    if (v != null) await _set('ua', v, msg: v.isEmpty ? '已恢复默认 User-Agent' : 'User-Agent 已保存');
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
    final enabled = on.isEmpty || on == 'true' || on == '1' || on == 'on';
    if (!enabled) return 'off';
    final cfg = g('m3u8FilterConfig');
    if (cfg.contains('"mode":"mild"') || cfg.contains('"mode": "mild"')) return 'mild';
    // 旧版「暴力」配置 → 温和（只去断点）
    if (cfg.contains('"violentFilterModeFlag":true')) return 'mild';
    return 'smart';
  }

  Future<void> _setAdMode(String mode) async {
    if (mode == 'off') {
      await _setMany({
        'adFilter': 'false',
        'm3u8FilterConfig': '',
      }, msg: '广告过滤已关闭');
    } else if (mode == 'mild') {
      await _setMany({
        'adFilter': 'true',
        'm3u8FilterConfig': '{"mode":"mild"}',
      }, msg: '已开启温和过滤（仅去断点）');
    } else {
      await _setMany({
        'adFilter': 'true',
        'm3u8FilterConfig': '{"mode":"smart"}',
      }, msg: '已开启智能过滤');
    }
  }

  Future<void> _pickAd() async {
    final v = await pickChoice(context, title: '广告过滤', current: _adMode, options: const [
      ('关闭', 'off'),
      ('智能（推荐）', 'smart'),
      ('温和（仅去断点）', 'mild'),
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
              ? '将清理爬虫包、磁力缓冲、日志、HTTP/封面等，以及 UI 侧临时文件。\n保留设置与数据库（观看历史等）。\n清理爬虫包后会自动重载点播源。'
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
    // 引擎与 UI 均在同一数据根（如 %APPDATA%/KOTV）；另扫系统临时目录残留。
    try {
      await kotvClearFlutterEphemeral();
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

  Future<void> _applyEngineUrl(String raw) async {
    final launcher = ref.read(engineLauncherProvider);
    final normalized = kotvNormalizeEngineBaseUrl(raw);
    _engineCtrl.text = normalized;
    final prefs = await SharedPreferences.getInstance();

    // 空 / 本机：立即切回本机，清远端登录态
    if (normalized.isEmpty || kotvIsLocalEngineBaseUrl(normalized)) {
      await prefs.remove('engine_base_url_draft');
      await prefs.remove('engine_base_url');
      await prefs.remove('remote_username');
      await kotvClearAuthToken();
      launcher.applyBaseUrl('');
      ref.read(apiProvider).baseUrl = launcher.baseUrl;
      if (!mounted) return;
      setState(() {
        _remoteUser = '';
        _status = '已使用本机引擎';
      });
      ref.invalidate(engineReadyProvider);
      ref.invalidate(configProvider);
      ref.invalidate(homeProvider);
      ref.invalidate(settingsProvider);
      showAppNews(context, '已切换为本机引擎\n${launcher.baseUrl}');
      return;
    }

    // 远端：只探测，不切换业务引擎；未登录继续用本机仓
    await prefs.setString('engine_base_url_draft', normalized);
    if (!mounted) return;
    setState(() => _status = '正在探测 $normalized…');

    final probe = KotvApi(baseUrl: normalized);
    try {
      final h = await probe.health().timeout(const Duration(seconds: 6));
      if (h['ok'] != true) {
        throw Exception('${h['error'] ?? '引擎未就绪'}');
      }
      // spider/runtime 未就绪也提示，但仍允许尝试登录
      final spiderOk = h['spiderOk'];
      if (spiderOk == false) {
        if (!mounted) return;
        showAppNews(context, '引擎可达，但爬虫未就绪\n$normalized\n${h['spiderError'] ?? ''}');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '探测失败: $e');
      showAppNews(context, '无法连接远端\n$normalized\n$e\n仍使用本机引擎');
      return;
    }

    var allowReg = false;
    try {
      final st = await probe.authStatus().timeout(const Duration(seconds: 4));
      allowReg = st['allowRegister'] == true;
    } catch (_) {}

    if (!mounted) return;

    final login = await showRemoteLoginDialog(
      context,
      ref,
      api: probe,
      allowRegister: allowReg,
      allowCancel: true,
      title: '远端登录',
      subtitle: '登录成功后才使用远端仓库与能力；取消则继续本机',
    );
    if (!mounted) return;
    if (!login.ok) {
      setState(() => _status = '已取消远端登录，继续本机');
      showAppNews(context, '未登录远端，继续使用本机引擎');
      return;
    }

    // 登录成功：才切换业务引擎
    await prefs.setString('engine_base_url', normalized);
    await prefs.setString('remote_username', login.username);
    launcher.applyBaseUrl(normalized);
    ref.read(apiProvider).baseUrl = launcher.baseUrl;
    setState(() {
      _remoteUser = login.username;
      _status = '远端已登录：${login.username}';
    });
    ref.invalidate(engineReadyProvider);
    ref.invalidate(configProvider);
    ref.invalidate(homeProvider);
    ref.invalidate(settingsProvider);
    showAppNews(context, '登录成功\n用户：${login.username}\n$normalized');
  }

  Future<void> _logoutRemote() async {
    final launcher = ref.read(engineLauncherProvider);
    final prefs = await SharedPreferences.getInstance();
    try {
      await ref.read(apiProvider).logout();
    } catch (_) {
      await kotvClearAuthToken();
    }
    await prefs.remove('engine_base_url');
    await prefs.remove('remote_username');
    // draft 保留，方便再次登录
    launcher.applyBaseUrl('');
    ref.read(apiProvider).baseUrl = launcher.baseUrl;
    if (!mounted) return;
    setState(() {
      _remoteUser = '';
      _status = '已退出远端，回到本机';
    });
    ref.invalidate(engineReadyProvider);
    ref.invalidate(configProvider);
    ref.invalidate(homeProvider);
    ref.invalidate(settingsProvider);
    showAppNews(context, '已退出远端登录\n当前使用本机引擎');
  }

  Future<void> _engineLogin() async {
    // 兼容入口：对当前草稿/远端地址走同一套探测+登录
    final draft = _engineCtrl.text.trim();
    if (draft.isEmpty || kotvIsLocalEngineBaseUrl(kotvNormalizeEngineBaseUrl(draft))) {
      showAppNews(context, '请先填写远端引擎地址');
      return;
    }
    await _applyEngineUrl(draft);
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

    final playerVal = kotvClampPlayerVal(g('player', kotvDefaultVodPlayer()), live: false);
    final playerLabel = flutterPlayerLabel(playerVal);
    final livePlayerVal = kotvClampPlayerVal(g('playerLive', kotvDefaultLivePlayer()), live: true);
    final livePlayerLabel = flutterPlayerLabel(livePlayerVal);
    final speed = g('playerSpeed', '1.0');
    final scale = g('playerScale', 'default');
    final scaleLive = g('playerScaleLive', scale);
    final decode = g('playerDecode', 'auto');
    final render = kotvNormalizePlayerRender(g('playerRender', 'surface'));
    final playerFailover = g('playerFailover', 'auto');
    final liveAutoChange = g('liveChange', 'true');
    final danOn = g('danmaku', 'false') == 'true';
    final incognito = g('incognito', 'false') == 'true';
    final dmr = g('dlnaRenderer', 'false') == 'true';
    final backendProxyPlay = g('backendProxyPlay', 'false') == 'true';
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
    final scaleLiveLabel = {
          'default': '适应',
          'fill': '拉伸',
          'zoom': 'Zoom',
          '16:9': '16:9',
          '4:3': '4:3',
        }[scaleLive] ??
        scaleLive;
    final decodeLabel = {'auto': '自动', 'soft': '软解码', 'hard': '硬解码'}[decode] ?? decode;
    final renderLabel = kotvPlayerRenderLabel(render);
    final failoverLabel = (playerFailover == 'off' || playerFailover == 'false') ? '关闭' : '自动';
    final liveChangeLabel = (liveAutoChange == 'false' || liveAutoChange == 'off') ? '关闭' : '开启';
    final adLabel = {'off': '关闭', 'smart': '智能', 'mild': '温和', 'on': '智能'}[ad] ?? ad;
    final themeLabel = {'dark': '深色', 'light': '浅色', 'system': '跟随系统'}[theme] ?? theme;
    final audioPassThrough = kotvSettingsFlag(g('audioPassThrough', 'true'), def: true);
    final videoEq = g('videoEq', 'off').trim().toLowerCase();
    final videoEqLabel = KotvVideoEq.presetLabels[videoEq == 'on' ? 'custom' : videoEq] ?? '关闭';
    final audioEq = g('audioEq', 'off').trim().toLowerCase();
    final audioEqLabel = switch (audioEq) {
      'natural' => '自然',
      'voice' || 'vocal' => '人声',
      'cinema' => '影院',
      'bass' => '低音',
      'treble' => '高音',
      'pop' => '流行',
      'rock' => '摇滚',
      'dance' => '舞曲',
      'electronic' => '电子',
      'hiphop' => '嘻哈',
      'jazz' => '爵士',
      'classical' => '古典',
      'custom' => '自定义',
      _ => '关闭',
    };
    // 全平台：点播/直播任一选了内置 MPV 才露出 MPV 相关项
    final usesMpv = kotvEmbedBackend(playerVal) == KotvEmbedBackend.mpv ||
        kotvEmbedBackend(livePlayerVal) == KotvEmbedBackend.mpv;
    final showMpvOpts = usesMpv && (kotvIsAndroid() || kotvIsDesktop() || kotvIsIOS());
    final showMpvVulkan = usesMpv &&
        ((kotvIsDesktop() || kotvIsIOS()) || (kotvIsAndroid() && _androidVulkanOk));
    final showMpvGpuNext = usesMpv && kotvIsAndroid();
    final showMpvTls = usesMpv && kotvIsAndroid();

    return Column(
      children: [
        LibraryTopBar(
          onBack: () => kotvPageBack(ref),
          onSearch: () => goKotvPage(ref, KotvPage.search),
          onProfile: () => goKotvPage(ref, KotvPage.profile),
          onNews: () => showAppNews(context, '同一局域网内浏览器打开\nhttp://<本机IP>:$_port/\n（Web 包为客户端；普通引擎为遥控。遥控见 /remote/）'),
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
                    const KotvSettingsSectionTitle('数据源'),
                    KotvSettingsCard(children: [
                      KotvSettingsWideTile(label: '首页数据源', value: homeName, onTap: () => _pickHome(sites)),
                      KotvSettingsGrid(children: [
                        KotvSettingsCell(
                          label: '点播源',
                          value: () {
                            final desc = _vodDesc.trim().isNotEmpty ? _vodDesc.trim() : g('vod');
                            return desc.isEmpty ? '未配置' : desc;
                          }(),
                          onTap: () async {
                            await showAddVodDialog(context, ref);
                            await _reload();
                          },
                          onLongPress: () async {
                            await showEditVodDialog(context, ref);
                            await _reload();
                            setState(() => _status = '点播源已更新');
                          },
                        ),
                        KotvSettingsCell(
                          label: '直播源',
                          value: () {
                            final desc = _liveDesc.trim().isNotEmpty ? _liveDesc.trim() : g('live');
                            return desc.isEmpty ? '未配置' : desc;
                          }(),
                          onTap: () async {
                            await showAddLiveDialog(context, ref);
                            await _reload();
                            setState(() => _status = '直播源已保存');
                          },
                          onLongPress: () async {
                            await showEditLiveDialog(context, ref);
                            await _reload();
                            setState(() => _status = '直播源已更新');
                          },
                        ),
                        KotvSettingsCell(
                          label: '线路选择',
                          value: '多仓',
                          onTap: () async {
                            final switched = await showRepoPicker(context, ref);
                            await _reload();
                            if (switched) {
                              setState(() => _status = '线路已切换');
                            }
                          },
                        ),
                        KotvSettingsCell(
                          label: '直播历史',
                          value: '切换',
                          onTap: () async {
                            await showLivePicker(context, ref);
                            await _reload();
                            setState(() => _status = '直播源已切换');
                          },
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
                        KotvSettingsCell(
                          label: '代理',
                          value: g('proxy').isEmpty ? '未配置' : g('proxy'),
                          onTap: () => _prompt('代理', 'false# 或 true#http://127.0.0.1:7890', g('proxy'), (v) => _set('proxy', v, msg: '代理已更新')),
                        ),
                        if (!kIsWeb)
                          KotvSettingsCell(
                            label: '引擎地址',
                            value: _engineCtrl.text.isNotEmpty ? _engineCtrl.text : launcher.baseUrl,
                            onTap: () => _prompt(
                              '引擎地址（http / https）',
                              'http://192.168.1.8:9978 或 https://engine.example.com',
                              _engineCtrl.text.isEmpty ? launcher.baseUrl : _engineCtrl.text,
                              _applyEngineUrl,
                            ),
                          ),
                        if (!kIsWeb)
                          KotvSettingsCell(
                            label: kotvIsLocalEngineBaseUrl(launcher.baseUrl) ? '远端登录' : '远端账号',
                            value: kotvIsLocalEngineBaseUrl(launcher.baseUrl)
                                ? '未连接'
                                : (_remoteUser.isNotEmpty ? '$_remoteUser · 退出' : '退出'),
                            onTap: () async {
                              if (!kotvIsLocalEngineBaseUrl(launcher.baseUrl)) {
                                await _logoutRemote();
                                return;
                              }
                              await _engineLogin();
                            },
                          ),
                      ]),
                    ]),
                    const KotvSettingsSectionTitle('播放器'),
                    KotvSettingsCard(children: [
                      KotvSettingsGrid(children: [
                        KotvSettingsCell(
                          label: '点播播放器',
                          value: playerLabel,
                          onTap: kotvCanSwitchPlayer(live: false)
                              ? () => _pick('点播播放器', 'player', kotvVodPlayerOptions(), msg: '点播播放器已切换')
                              : () => showAppNews(context, 'Web 端仅支持浏览器 HTML5 播放（无法使用 MPV/FVP）'),
                        ),
                        KotvSettingsCell(
                          label: '直播播放器',
                          value: livePlayerLabel,
                          onTap: kotvCanSwitchPlayer(live: true)
                              ? () => _pick(
                                    '直播播放器',
                                    'playerLive',
                                    kotvLivePlayerOptions(),
                                    msg: '直播播放器已切换',
                                  )
                              : () => showAppNews(context, 'Web 端仅支持浏览器 HTML5 播放（无法使用 MPV/FVP）'),
                        ),
                        KotvSettingsCell(
                          label: '解码方式',
                          value: decodeLabel,
                          onTap: () => _pick('解码方式', 'playerDecode', const [
                            ('自动（推荐）', 'auto'),
                            ('软解码', 'soft'),
                            ('硬解码', 'hard'),
                          ]),
                        ),
                        if (kotvIsAndroid() &&
                            (kotvPlayerRenderApplies(playerVal) || kotvPlayerRenderApplies(livePlayerVal)))
                          KotvSettingsCell(
                            label: '渲染方式',
                            value: renderLabel,
                            onTap: () => _pick('渲染方式（Exo / 原生 MPV）', 'playerRender', const [
                              ('Surface（推荐，HDR）', 'surface'),
                              ('Texture', 'texture'),
                            ], msg: '仅 Android 内置 Exo / 原生 MPV 生效，已保存'),
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
                          label: '直播画面比例',
                          value: scaleLiveLabel,
                          onTap: () => _pick('直播画面比例', 'playerScaleLive', const [
                            ('适应', 'default'),
                            ('拉伸', 'fill'),
                            ('Zoom', 'zoom'),
                            ('16:9', '16:9'),
                            ('4:3', '4:3'),
                          ]),
                        ),
                        KotvSettingsCell(
                          label: '自动切换播放器',
                          value: failoverLabel,
                          onTap: () => _pick('自动切换播放器', 'playerFailover', const [
                            ('自动（黑屏/停滞时换播放器）', 'auto'),
                            ('关闭（只用所选播放器）', 'off'),
                          ]),
                        ),
                        KotvSettingsCell(
                          label: '直播失败换线',
                          value: liveChangeLabel,
                          onTap: () => _pick('直播失败换线', 'liveChange', const [
                            ('开启（失败自动下一线路）', 'true'),
                            ('关闭', 'false'),
                          ]),
                        ),
                        KotvSettingsCell(
                          label: '跨分组换台',
                          value: (g('liveAcross', 'true') == 'false') ? '关闭' : '开启',
                          onTap: () => unawaited(_set(
                            'liveAcross',
                            g('liveAcross', 'true') == 'false' ? 'true' : 'false',
                            msg: '跨分组换台已更新',
                          )),
                        ),
                        KotvSettingsCell(
                          label: '换台方向反转',
                          value: (g('liveInvert', 'false') == 'true') ? '开启' : '关闭',
                          onTap: () => unawaited(_set(
                            'liveInvert',
                            g('liveInvert', 'false') == 'true' ? 'false' : 'true',
                            msg: '换台方向已更新',
                          )),
                        ),
                        KotvSettingsCell(
                          label: '开机进直播',
                          value: (g('bootLive', 'false') == 'true') ? '开启' : '关闭',
                          onTap: () => unawaited(_set(
                            'bootLive',
                            g('bootLive', 'false') == 'true' ? 'false' : 'true',
                            msg: '开机进直播已更新',
                          )),
                        ),
                        KotvSettingsCell(
                          label: '预加载下一集',
                          value: (g('preloadNextEpisode', 'true') == 'false') ? '关闭' : '开启',
                          onTap: () => unawaited(_set(
                            'preloadNextEpisode',
                            g('preloadNextEpisode', 'true') == 'false' ? 'true' : 'false',
                            msg: '预加载下一集已更新',
                          )),
                        ),
                        if (kotvIsAndroid())
                          KotvSettingsCell(
                            label: '音频直通',
                            value: audioPassThrough ? '开启' : '关闭',
                            onTap: () => unawaited(_set(
                              'audioPassThrough',
                              audioPassThrough ? 'false' : 'true',
                              msg: audioPassThrough
                                  ? '已关闭音频直通（重启播放生效）'
                                  : '已开启音频直通（重启播放生效）',
                            )),
                          ),
                        if (kotvIsAndroid())
                          KotvSettingsCell(
                            label: 'Exo 设置',
                            value: '缓存 / 缓冲 / 隧道…',
                            onTap: () => unawaited(_openExoSheet()),
                          ),
                        if (showMpvOpts)
                          KotvSettingsCell(
                            label: 'MPV 设置',
                            value: 'Vulkan / 配置…',
                            onTap: () => unawaited(_openMpvSheet(
                              showGpuNext: showMpvGpuNext,
                              showVulkan: showMpvVulkan,
                              showTls: showMpvTls,
                            )),
                          ),
                        KotvSettingsCell(
                          label: '画面调色',
                          value: videoEqLabel,
                          onTap: () => unawaited(_openVideoEqSheet()),
                        ),
                        KotvSettingsCell(
                          label: '音频均衡',
                          value: audioEqLabel,
                          onTap: () => unawaited(_openAudioEqSheet()),
                        ),
                        KotvSettingsCell(
                          label: '字幕样式',
                          value: '字号 ${g("subtitleFontScale", "1.0")}',
                          onTap: () => unawaited(_openSubtitleSheet()),
                        ),
                      ]),
                    ]),
                    const KotvSettingsSectionTitle('功能'),
                    KotvSettingsCard(children: [
                      KotvSettingsGrid(children: [
                        KotvSettingsCell(label: '广告过滤', value: adLabel, onTap: _pickAd),
                        KotvSettingsCell(
                          label: '弹幕',
                          value: danOn ? '开启' : '关闭',
                          onTap: () => unawaited(_openDanmakuSheet()),
                        ),
                        KotvSettingsCell(
                          label: '无痕模式',
                          value: incognito ? '开启' : '关闭',
                          onTap: () => _set('incognito', incognito ? 'false' : 'true', msg: incognito ? '无痕已关闭' : '无痕已开启'),
                        ),
                        KotvSettingsCell(
                          label: '远端网盘经后端加速',
                          value: backendProxyPlay ? '开启' : '关闭',
                          onTap: () => _set(
                            'backendProxyPlay',
                            backendProxyPlay ? 'false' : 'true',
                            msg: backendProxyPlay
                                ? '已关闭：远端优先直连 CDN（本机仍走本地代理）'
                                : '已开启：远端也走引擎 /proxy（原生库/go/Java 多线程）',
                          ),
                        ),
                        KotvSettingsCell(
                          label: '投屏接收',
                          value: dmr ? '开启' : '关闭',
                          onTap: () => _set('dlnaRenderer', dmr ? 'false' : 'true', msg: dmr ? '已关闭 DLNA 被投端' : '已开启 DLNA 被投端'),
                        ),
                        KotvSettingsCell(label: '投屏', value: 'DLNA', onTap: _cast),
                        KotvSettingsCell(
                          label: 'User-Agent',
                          value: g('ua').isEmpty ? '默认' : _ellipsize(g('ua'), 22),
                          onTap: _editUa,
                        ),
                        KotvSettingsCell(
                          label: 'Assrt Token',
                          value: g('assrtToken').isEmpty ? '未配置' : '已配置',
                          onTap: () => _prompt('Assrt Token', 'token', g('assrtToken'), (v) => _set('assrtToken', v)),
                        ),
                        KotvSettingsCell(
                          label: 'Web / 遥控',
                          value: ':$_port',
                          onTap: () => showAppNews(context, '同一局域网内浏览器打开\nhttp://<本机IP>:$_port/\n（Web 包有 webapp 时为客户端；否则为遥控。遥控固定 /remote/）'),
                        ),
                        KotvSettingsCell(
                          label: '用户管理',
                          value: '管理员',
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(builder: (_) => const UserAdminScreen()),
                            );
                          },
                        ),
                      ]),
                    ]),
                    const KotvSettingsSectionTitle('界面'),
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
                    const KotvSettingsSectionTitle('隐私与同步'),
                    KotvSettingsCard(children: [
                      KotvSettingsGrid(columns: 4, children: [
                        KotvSettingsCell(label: '配对码', value: _pairCode.isEmpty ? '查看' : _pairCode, onTap: _showPair),
                        KotvSettingsCell(label: '重置配对码', onTap: _resetPair),
                        KotvSettingsCell(label: '发送历史', onTap: () => _syncSend('history')),
                        KotvSettingsCell(label: '发送收藏', onTap: () => _syncSend('keep')),
                      ]),
                    ]),
                    const KotvSettingsSectionTitle('更多'),
                    KotvSettingsCard(children: [
                      KotvSettingsGrid(columns: 4, children: [
                        KotvSettingsCell(
                          label: '更新地址',
                          value: g('updateUrl').isEmpty ? '未配置' : g('updateUrl'),
                          onTap: () => _prompt('更新地址', 'version.json URL', g('updateUrl'), (v) => _set('updateUrl', v)),
                        ),
                        KotvSettingsCell(label: '数据备份', onTap: _backupExport),
                        KotvSettingsCell(label: '恢复备份', onTap: _backupImport),
                        KotvSettingsCell(label: '清理缓存', onTap: _clearCache),
                        if (!Platform.isIOS) KotvSettingsCell(label: '检测爬虫', onTap: _checkSpider),
                        KotvSettingsCell(label: '检查更新', value: _version, onTap: _checkUpdate),
                        KotvSettingsCell(label: '运行库', onTap: () => _showRuntime(launcher, cfg)),
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
