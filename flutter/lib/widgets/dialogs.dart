import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';

import '../theme/layout_scale.dart';
import '../theme/kotv_palette.dart';
import '../theme/kotv_theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../providers.dart';
import 'chrome.dart';

/// 弹窗尺寸：窄屏用满宽减边距，避免固定 720 被压成竖条。
({double width, double height, EdgeInsets inset, bool compact}) _dialogMetrics(BuildContext context) {
  final sz = MediaQuery.sizeOf(context);
  final compact = sz.width < 640 || sz.shortestSide < 560;
  final inset = compact ? const EdgeInsets.symmetric(horizontal: 10, vertical: 12) : const EdgeInsets.symmetric(horizontal: 48, vertical: 40);
  final innerW = sz.width - inset.horizontal;
  final innerH = sz.height - inset.vertical;
  final width = innerW.clamp(280.0, 720.0);
  final height = (innerH * (compact ? 0.86 : 0.82)).clamp(compact ? 300.0 : 360.0, 560.0);
  return (width: width, height: height, inset: inset, compact: compact);
}

// 添加源时选择本机配置文件。桌面走系统原生对话框。
const _configFileTypes = XTypeGroup(
  label: '配置文件',
  extensions: ['json', 'txt', 'xml', 'conf', 'yaml', 'yml'],
);

Future<String?> _pickConfigFile() async {
  final XFile? file = await openFile(acceptedTypeGroups: [_configFileTypes]);
  if (file == null) return null;
  return Uri.file(file.path).toString();
}

Future<void> showSitePicker(
  BuildContext context,
  WidgetRef ref, {
  required List<SiteInfo> sites,
  required Future<void> Function(String key) onSelect,
}) async {
  if (sites.isEmpty) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) {
      var local = List<SiteInfo>.from(sites);
      final m = _dialogMetrics(ctx);
      return StatefulBuilder(
        builder: (ctx, setLocal) {
          Future<void> reload() async {
            final cfg = await ref.read(apiProvider).getConfig();
            final list = ((cfg['sites'] as List?) ?? [])
                .whereType<Map>()
                .map((e) => SiteInfo.fromJson(Map<String, dynamic>.from(e)))
                .toList();
            setLocal(() => local = list);
            ref.invalidate(configProvider);
          }

          return Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: m.inset,
            child: SizedBox(
              width: m.width,
              height: m.height,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: KotvPalette.of(ctx).dialogBg,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: KotvPalette.of(ctx).outline),
                ),
                child: Padding(
                  padding: EdgeInsets.fromLTRB(m.compact ? 14 : 28, m.compact ? 14 : 24, m.compact ? 14 : 28, m.compact ? 12 : 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '换源',
                              style: TextStyle(
                                color: KotvPalette.of(ctx).fg,
                                fontSize: m.compact ? 20 : 26,
                                fontWeight: FontWeight.w700,
                                height: 1.2,
                              ),
                            ),
                          ),
                          AppPill(label: '关闭', width: m.compact ? 72 : 96, height: 36, onTap: () => Navigator.pop(ctx)),
                        ],
                      ),
                      SizedBox(height: m.compact ? 6 : 8),
                      Text(
                        '点名称切换；右侧图标：可搜索 / 可换源（长按=全部）',
                        maxLines: m.compact ? 1 : null,
                        overflow: m.compact ? TextOverflow.ellipsis : TextOverflow.visible,
                        softWrap: !m.compact,
                        style: TextStyle(
                          color: KotvPalette.of(ctx).muted,
                          fontSize: m.compact ? 11 : 14,
                          height: m.compact ? 1.1 : 1.35,
                        ),
                      ),
                      SizedBox(height: m.compact ? 10 : 16),
                      Expanded(
                        child: ListView.separated(
                          itemCount: local.length,
                          separatorBuilder: (_, __) => SizedBox(height: m.compact ? 4 : 8),
                          itemBuilder: (_, i) {
                            final s = local[i];
                            if (m.compact) {
                              return Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Expanded(
                                    child: AppPill(
                                      label: s.name,
                                      height: 40,
                                      selected: s.home,
                                      autofocus: i == 0,
                                      onTap: () {
                                        Navigator.pop(ctx);
                                        onSelect(s.key);
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  _CircleIcon(
                                    icon: s.searchable ? Icons.search : Icons.visibility_off,
                                    onTap: () async {
                                      await ref.read(apiProvider).toggleSite(field: 'searchable', key: s.key);
                                      await reload();
                                    },
                                    onLongPress: () async {
                                      await ref.read(apiProvider).toggleSite(field: 'searchable', all: !s.searchable);
                                      await reload();
                                    },
                                  ),
                                  const SizedBox(width: 8),
                                  _CircleIcon(
                                    icon: s.changeable ? Icons.refresh : Icons.visibility_off,
                                    onTap: () async {
                                      await ref.read(apiProvider).toggleSite(field: 'changeable', key: s.key);
                                      await reload();
                                    },
                                    onLongPress: () async {
                                      await ref.read(apiProvider).toggleSite(field: 'changeable', all: !s.changeable);
                                      await reload();
                                    },
                                  ),
                                ],
                              );
                            }
                            return Row(
                              children: [
                                Expanded(
                                  child: AppPill(
                                    label: s.name,
                                    height: 44,
                                    selected: s.home,
                                    autofocus: i == 0,
                                    onTap: () {
                                      Navigator.pop(ctx);
                                      onSelect(s.key);
                                    },
                                  ),
                                ),
                                const SizedBox(width: 8),
                                _CircleIcon(
                                  icon: s.searchable ? Icons.search : Icons.search_off,
                                  onTap: () async {
                                    await ref.read(apiProvider).toggleSite(field: 'searchable', key: s.key);
                                    await reload();
                                  },
                                  onLongPress: () async {
                                    await ref.read(apiProvider).toggleSite(field: 'searchable', all: !s.searchable);
                                    await reload();
                                  },
                                ),
                                const SizedBox(width: 6),
                                _CircleIcon(
                                  icon: s.changeable ? Icons.refresh : Icons.visibility_off,
                                  onTap: () async {
                                    await ref.read(apiProvider).toggleSite(field: 'changeable', key: s.key);
                                    await reload();
                                  },
                                  onLongPress: () async {
                                    await ref.read(apiProvider).toggleSite(field: 'changeable', all: !s.changeable);
                                    await reload();
                                  },
                                ),
                              ],
                            );
                          },
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
}

Future<void> showAddVodDialog(BuildContext context, WidgetRef ref) async {
  final api = ref.read(apiProvider);
  String initial = '';
  try {
    final cfg = await api.getConfig();
    initial = '${cfg['source'] ?? ''}';
  } catch (_) {}
  if (!context.mounted) return;
  final ctrl = TextEditingController(text: initial);
  var busy = false;
  String status = '';

  await showDialog<void>(
    context: context,
    barrierDismissible: !busy,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setLocal) {
          Future<void> load(String src) async {
            src = src.trim();
            if (src.isEmpty) {
              setLocal(() => status = '请输入 URL 或粘贴 JSON');
              return;
            }
            setLocal(() {
              busy = true;
              status = '加载配置中…';
            });
            try {
              await api.loadConfig(src);
              ref.invalidate(configProvider);
              ref.invalidate(homeProvider);
              ref.invalidate(settingsProvider);
              if (ctx.mounted) Navigator.pop(ctx);
            } catch (e) {
              setLocal(() {
                busy = false;
                status = '$e';
              });
            }
          }

          Future<void> pick() async {
            final picked = await _pickConfigFile();
            if (picked != null && ctx.mounted) {
              ctrl.text = picked;
              await load(picked);
            }
          }

          final p = KotvPalette.of(ctx);
          return Dialog(
            backgroundColor: Colors.transparent,
            child: Container(
              width: 520,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: p.dialogBg,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: p.outline),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('添加点播源', style: TextStyle(color: p.fg, fontSize: 22, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  Text('支持单线路、多仓索引、本地路径，或 {"sites":[…]} JSON', style: TextStyle(color: p.muted, fontSize: 13)),
                  const SizedBox(height: 12),
                  TextField(
                    controller: ctrl,
                    maxLines: 4,
                    enabled: !busy,
                    style: TextStyle(color: p.fg),
                    cursorColor: p.primary,
                    decoration: InputDecoration(
                      hintText: '配置地址、多仓索引，或粘贴 JSON…',
                      hintStyle: TextStyle(color: p.muted),
                      filled: true,
                      fillColor: p.input,
                    ),
                  ),
                  if (status.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(status, style: TextStyle(color: p.primary, fontSize: 13)),
                  ],
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      AppPill(
                        label: '选择本地',
                        width: 112,
                        onTap: busy ? () {} : () => pick(),
                      ),
                      const Spacer(),
                      AppPill(label: '取消', width: 96, onTap: busy ? () {} : () => Navigator.pop(ctx)),
                      const SizedBox(width: 10),
                      AppPill(
                        label: busy ? '加载中…' : '加载',
                        width: 96,
                        selected: true,
                        onTap: busy ? () {} : () => load(ctrl.text),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
  ctrl.dispose();
}

Future<void> showAddLiveDialog(BuildContext context, WidgetRef ref) async {
  final api = ref.read(apiProvider);
  String initial = '';
  try {
    final st = await api.getSettings();
    final map = Map<String, dynamic>.from((st['settings'] as Map?) ?? {});
    initial = '${map['live'] ?? ''}';
  } catch (_) {}
  if (!context.mounted) return;
  final ctrl = TextEditingController(text: initial);

  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      final p = KotvPalette.of(ctx);
      Future<void> pick() async {
        final picked = await _pickConfigFile();
        if (picked != null && ctx.mounted) {
          ctrl.text = picked;
          Navigator.pop(ctx, true);
        }
      }
      return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 520,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: p.dialogBg,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: p.outline),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('直播源', style: TextStyle(color: p.fg, fontSize: 22, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text('可填在线 M3U/TXT/JSON 地址，或本机路径', style: TextStyle(color: p.muted, fontSize: 13)),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              style: TextStyle(color: p.fg),
              cursorColor: p.primary,
              decoration: InputDecoration(
                hintText: 'M3U/TXT/JSON URL 或本地路径',
                hintStyle: TextStyle(color: p.muted),
                filled: true,
                fillColor: p.input,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                AppPill(label: '选择本地', width: 112, onTap: () => pick()),
                const Spacer(),
                AppPill(label: '取消', width: 96, onTap: () => Navigator.pop(ctx, false)),
                const SizedBox(width: 10),
                AppPill(label: '保存', width: 96, selected: true, onTap: () => Navigator.pop(ctx, true)),
              ],
            ),
          ],
        ),
      ),
    );
    },
  );
  if (ok == true) {
    final src = ctrl.text.trim();
    if (src.isNotEmpty) {
      await api.setSetting('live', src);
      ref.invalidate(settingsProvider);
    }
  }
  ctrl.dispose();
}

/// 已保存的直播源列表。返回 true 表示已切换或新加，调用方应刷新。
Future<bool> showLivePicker(BuildContext context, WidgetRef ref) async {
  final api = ref.read(apiProvider);
  Map<String, dynamic> data;
  try {
    data = await api.liveSources();
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
    return false;
  }
  if (!context.mounted) return false;
  final selected = await showDialog<String>(
    context: context,
    builder: (ctx) {
      var local = data;
      return StatefulBuilder(
        builder: (ctx, setLocal) {
          Future<void> reload() async {
            final d = await api.liveSources();
            setLocal(() => local = d);
          }

          final list = ((local['configs'] as List?) ?? []).whereType<Map>().toList();
          final current = '${local['live'] ?? ''}';
          final m = _dialogMetrics(ctx);
          return Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: m.inset,
            child: SizedBox(
              width: m.width,
              height: m.height,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: KotvPalette.of(ctx).dialogBg,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: KotvPalette.of(ctx).outline),
                ),
                child: Padding(
                  padding: EdgeInsets.all(m.compact ? 14 : 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '直播源',
                        style: TextStyle(color: KotvPalette.of(ctx).fg, fontSize: m.compact ? 20 : 22, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 6),
                      Text('点选切换；右侧删除可移除', style: TextStyle(color: KotvPalette.of(ctx).muted, fontSize: 14)),
                      const SizedBox(height: 12),
                      Expanded(
                        child: ListView(
                          children: [
                            ...() {
                              final rows = <Widget>[];
                              var focused = false;
                              for (final r in list) {
                                final url = '${r['url'] ?? ''}';
                                final isCurrent = r['current'] == true || url == current;
                                final name = '${r['name'] ?? url}';
                                rows.add(
                                  _RepoRow(
                                    label: '$name${isCurrent ? '（当前）' : ''}',
                                    autofocus: !focused,
                                    onTap: isCurrent ? () {} : () => Navigator.pop(ctx, url),
                                    onDelete: isCurrent
                                        ? null
                                        : () async {
                                            await api.deleteLive(url);
                                            await reload();
                                          },
                                  ),
                                );
                                rows.add(const SizedBox(height: 8));
                                focused = true;
                              }
                              rows.add(
                                _RepoRow(
                                  label: '＋ 添加直播源',
                                  autofocus: !focused,
                                  onTap: () => Navigator.pop(ctx, ''),
                                  onDelete: null,
                                ),
                              );
                              return rows;
                            }(),
                          ],
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: AppPill(label: '关闭', width: m.compact ? 72 : 96, height: 36, onTap: () => Navigator.pop(ctx)),
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
  if (!context.mounted) return false;
  if (selected == null) return false;
  if (selected.isEmpty) {
    await showAddLiveDialog(context, ref);
    return true;
  }
  await api.setSetting('live', selected);
  return true;
}

/// 多仓/线路切换。返回 true 表示已成功切换并应刷新首页。
Future<bool> showRepoPicker(BuildContext context, WidgetRef ref) async {
  final api = ref.read(apiProvider);
  Map<String, dynamic> data;
  try {
    data = await api.listRepos();
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
    return false;
  }
  final current = '${data['current'] ?? ''}';

  if (!context.mounted) return false;
  final selected = await showDialog<String>(
    context: context,
    builder: (ctx) {
      var local = data;
      return StatefulBuilder(
        builder: (ctx, setLocal) {
          Future<void> reload() async {
            final d = await api.listRepos();
            setLocal(() => local = d);
          }

          final list = ((local['repos'] as List?) ?? []).whereType<Map>().toList();
          final m = _dialogMetrics(ctx);
          return Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: m.inset,
            child: SizedBox(
              width: m.width,
              height: m.height,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xFA3B1970),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: const Color(0x70D8A5E8)),
                ),
                child: Padding(
                  padding: EdgeInsets.all(m.compact ? 14 : 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '线路选择',
                        style: TextStyle(color: Colors.white, fontSize: m.compact ? 20 : 22, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 6),
                      const Text('点选切换；右侧删除可移除', style: TextStyle(color: Color(0xFFCF4274), fontSize: 14)),
                      const SizedBox(height: 12),
                      Expanded(
                        child: ListView(
                          children: [
                            ...() {
                              final rows = <Widget>[];
                              var focused = false;
                              for (final r in list) {
                                final isCurrent = '${r['url']}' == current;
                                rows.add(
                                  _RepoRow(
                                    label: '${r['name'] ?? r['url']}${isCurrent ? '（当前）' : ''}',
                                    autofocus: !focused,
                                    onTap: isCurrent
                                        ? () {}
                                        : () => Navigator.pop(ctx, '${r['url']}'),
                                    onDelete: isCurrent
                                        ? null
                                        : () async {
                                            await api.deleteRepo('${r['url']}');
                                            await reload();
                                          },
                                  ),
                                );
                                rows.add(const SizedBox(height: 8));
                                focused = true;
                              }
                              rows.add(
                                _RepoRow(
                                  label: '＋ 添加线路',
                                  autofocus: !focused,
                                  onTap: () => Navigator.pop(ctx, ''),
                                  onDelete: null,
                                ),
                              );
                              return rows;
                            }(),
                          ],
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: AppPill(label: '关闭', width: m.compact ? 72 : 96, height: 36, onTap: () => Navigator.pop(ctx)),
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

  if (!context.mounted) return false;
  if (selected == null) return false;
  if (selected.isEmpty) {
    await showAddVodDialog(context, ref);
    return true;
  }

  final label = selected.length > 40 ? '${selected.substring(0, 40)}…' : selected;
  ref.read(uiBusyProvider.notifier).state = '切换线路中…\n$label';
  try {
    await api.loadConfig(selected);
    // 等引擎 ready，避免立刻 home 打到半截配置
    for (var i = 0; i < 40; i++) {
      final h = await api.health();
      if (h['ready'] == true) break;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    ref.invalidate(configProvider);
    ref.invalidate(homeProvider);
    ref.invalidate(settingsProvider);
    return true;
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('切换失败: $e')));
    }
    return false;
  } finally {
    ref.read(uiBusyProvider.notifier).state = null;
  }
}

Future<String?> pickChoice(
  BuildContext context, {
  required String title,
  required String current,
  required List<(String label, String value)> options,
}) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => SimpleDialog(
      backgroundColor: const Color(0xFF63248A),
      title: Text(title, style: const TextStyle(color: Colors.white)),
      children: [
        for (final o in options)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, o.$2),
            child: Text(
              o.$1 + (o.$2 == current ? '  ✓' : ''),
              style: const TextStyle(color: Colors.white),
            ),
          ),
      ],
    ),
  );
}

class _RepoRow extends StatelessWidget {
  const _RepoRow({required this.label, required this.onTap, this.onDelete, this.autofocus = false});
  final String label;
  final VoidCallback onTap;
  final VoidCallback? onDelete;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: AppPill(label: label, height: 44, autofocus: autofocus, onTap: onTap)),
        if (onDelete != null) ...[
          const SizedBox(width: 8),
          _CircleIcon(icon: Icons.delete_outline, onTap: onDelete!),
        ],
      ],
    );
  }
}

class _CircleIcon extends StatelessWidget {
  const _CircleIcon({required this.icon, required this.onTap, this.onLongPress});
  final IconData icon;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final p = KotvPalette.of(context);
    // 遥控器要能落到搜索/换源/删除；纯 InkWell 无焦点框。
    return TvFocus(
      onPressed: onTap,
      borderRadius: 18,
      child: Material(
        color: p.pillBg,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          onLongPress: onLongPress,
          child: SizedBox(width: 36, height: 36, child: Icon(icon, color: p.fg, size: 18)),
        ),
      ),
    );
  }
}

/// 设置分段标题 / 芯片 / 行（视觉更清晰）。
class SettingTitle extends StatelessWidget {
  const SettingTitle(this.label, {super.key, this.hint});
  final String label;
  final String? hint;
  @override
  Widget build(BuildContext context) {
    final p = KotvPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 18, 2, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: p.fg,
              fontSize: 15,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
          ),
          if (hint != null && hint!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(hint!, style: TextStyle(color: p.muted, fontSize: 12, height: 1.3)),
          ],
        ],
      ),
    );
  }
}

class SettingChip extends StatelessWidget {
  const SettingChip({super.key, required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = KotvPalette.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          constraints: const BoxConstraints(minWidth: 108, minHeight: 40),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: selected ? p.selected : p.pillBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? p.primary.withOpacity(0.9) : p.pillBorder,
              width: selected ? 1.2 : 1,
            ),
            boxShadow: selected
                ? [BoxShadow(color: p.selected.withOpacity(0.35), blurRadius: 12, offset: const Offset(0, 4))]
                : null,
          ),
          child: Center(
            child: Text(
              selected ? '✓ $label' : label,
              style: TextStyle(
                color: selected ? Colors.white : p.fg,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class SettingRow extends StatelessWidget {
  const SettingRow({
    super.key,
    required this.label,
    required this.value,
    required this.onTap,
    this.subtitle,
  });
  final String label;
  final String value;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = KotvPalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Ink(
            decoration: BoxDecoration(
              color: p.pillBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: p.pillBorder),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(label, style: TextStyle(color: p.fg, fontSize: 15, fontWeight: FontWeight.w600)),
                        if (subtitle != null && subtitle!.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(subtitle!, style: TextStyle(color: p.muted, fontSize: 12)),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      value,
                      textAlign: TextAlign.right,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: p.muted, fontSize: 13.5),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(Icons.chevron_right_rounded, color: p.muted, size: 20),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 设置页分组面板：把一组选项包进半透明卡片。
class SettingPanel extends StatelessWidget {
  const SettingPanel({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final p = KotvPalette.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 12),
      decoration: BoxDecoration(
        color: p.surface.withOpacity(p.light ? 0.55 : 0.35),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.outline.withOpacity(0.45)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    );
  }
}

// ---------------------------------------------------------------------------
// 截图风格：半透明大卡片 + 通栏行 / 三列网格
// ---------------------------------------------------------------------------

class KotvSettingsSectionTitle extends StatelessWidget {
  const KotvSettingsSectionTitle(this.label, {super.key});
  final String label;

  @override
  Widget build(BuildContext context) {
    final p = KotvPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 10),
      child: Text(
        label,
        style: TextStyle(color: p.fg, fontSize: 17, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class KotvSettingsCard extends StatelessWidget {
  const KotvSettingsCard({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final p = KotvPalette.of(context);
    final kids = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        kids.add(Divider(height: 1, thickness: 1, color: p.fg.withOpacity(0.08)));
      }
      kids.add(children[i]);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: ColoredBox(
        color: p.pillBg.withOpacity(0.72),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: kids),
      ),
    );
  }
}

/// 通栏设置行（左标题，右值 + ›）
class KotvSettingsWideTile extends StatelessWidget {
  const KotvSettingsWideTile({
    super.key,
    required this.label,
    this.value = '',
    required this.onTap,
  });
  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = KotvPalette.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Expanded(
                child: Text(label, style: TextStyle(color: p.fg, fontSize: 15, fontWeight: FontWeight.w500)),
              ),
              if (value.isNotEmpty)
                Flexible(
                  child: Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: TextStyle(color: p.muted, fontSize: 14),
                  ),
                ),
              const SizedBox(width: 4),
              Text('›', style: TextStyle(color: p.muted.withOpacity(0.7), fontSize: 18, height: 1)),
            ],
          ),
        ),
      ),
    );
  }
}

/// 网格单元格
class KotvSettingsCell extends StatelessWidget {
  const KotvSettingsCell({
    super.key,
    required this.label,
    this.value = '',
    required this.onTap,
    this.onLongPress,
  });
  final String label;
  final String value;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final p = KotvPalette.of(context);
    final oneCol = KotvSettingsGrid.effectiveColumns(context, 3) == 1;
    final labelStyle = TextStyle(
      color: p.fg,
      fontSize: oneCol ? 15 : 14,
      fontWeight: FontWeight.w500,
      height: 1.2,
    );
    final valueStyle = TextStyle(
      color: p.muted,
      fontSize: oneCol ? 14 : 13,
      height: 1.2,
    );
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: oneCol ? 14 : 12, vertical: oneCol ? 14 : 13),
          // 标签按内容宽，数值吃满剩余宽度（由布局 ellipsis，不再硬截 10 字）。
          child: Row(
            children: [
              Text(label, maxLines: 1, style: labelStyle),
              if (value.isNotEmpty) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    value,
                    maxLines: oneCol ? 2 : 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: valueStyle,
                  ),
                ),
              ] else
                const Spacer(),
              const SizedBox(width: 4),
              Text('›', style: TextStyle(color: p.muted.withOpacity(0.7), fontSize: oneCol ? 18 : 16, height: 1)),
            ],
          ),
        ),
      ),
    );
  }
}

/// N 列网格行（单元格之间细竖线）。窄屏自动降为 1 列，中等宽度 2 列。
class KotvSettingsGrid extends StatelessWidget {
  const KotvSettingsGrid({super.key, required this.children, this.columns = 3});
  final List<Widget> children;
  final int columns;

  static int effectiveColumns(BuildContext context, int columns) {
    final w = MediaQuery.sizeOf(context).width;
    if (KotvLayout.isCompact(context) || w < 640) return 1;
    if (w < 1000) return columns > 2 ? 2 : columns;
    return columns;
  }

  @override
  Widget build(BuildContext context) {
    final cols = effectiveColumns(context, columns);
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i += cols) {
      final end = i + cols > children.length ? children.length : i + cols;
      final slice = <Widget>[...children.sublist(i, end)];
      while (slice.length < cols) {
        slice.add(const SizedBox.shrink());
      }
      if (rows.isNotEmpty) {
        rows.add(Divider(height: 1, thickness: 1, color: Colors.white.withOpacity(0.08)));
      }
      rows.add(IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var c = 0; c < slice.length; c++) ...[
              if (c > 0) VerticalDivider(width: 1, thickness: 1, color: Colors.white.withOpacity(0.08)),
              Expanded(child: slice[c]),
            ],
          ],
        ),
      ));
    }
    return Column(children: rows);
  }
}
