import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../nav/kotv_page.dart';
import '../nav/kotv_routes.dart';
import '../providers.dart';
import '../desktop/mini_player_window.dart';
import '../player/playback_guard.dart';
import '../screens/detail_screen.dart';
import '../screens/folder_screen.dart';

/// 网盘授权等会写 `/TVBox/`；API 30+ 需「所有文件访问」。失败返回 false。
Future<bool> _ensureSharedStorageWrite() async {
  if (kIsWeb || !Platform.isAndroid) return true;
  try {
    const ch = MethodChannel('kotv_android');
    return await ch.invokeMethod<bool>('ensureStoragePermission') ?? false;
  } catch (_) {
    return false;
  }
}

/// 配置站 / 带 action 的项会写共享存储（网盘 cookie 等）。
bool siteNeedsSharedWrite(WidgetRef ref, String siteKey) {
  final cfg = ref.read(configProvider).valueOrNull;
  final sites = ((cfg?['sites'] as List?) ?? []).whereType<Map>();
  for (final s in sites) {
    if ('${s['key'] ?? ''}' != siteKey) continue;
    final api = '${s['api'] ?? ''}'.toLowerCase();
    return api.contains('config');
  }
  return false;
}

/// 配置站 / action 打开前弹出系统授权。未授予则拦住，不继续进授权页。
Future<bool> _gateSharedStorageWrite(BuildContext context, WidgetRef ref, String siteKey, {required bool force}) async {
  if (!force && !siteNeedsSharedWrite(ref, siteKey)) return true;
  final ok = await _ensureSharedStorageWrite();
  if (ok) return true;
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('需要授予存储权限才能保存网盘登录态'),
        duration: Duration(seconds: 4),
      ),
    );
  }
  return false;
}

/// detailContent 期间 jar 是否 finish 了详情层。读一次即清掉。
Future<bool> _consumeJarDetailDismissed() async {
  if (kIsWeb || !Platform.isAndroid) return false;
  try {
    const ch = MethodChannel('kotv_android');
    return await ch.invokeMethod<bool>('consumeJarDetailDismissed') ?? false;
  } catch (_) {
    return false;
  }
}

/// 用片名去全网搜索。
void searchByName(WidgetRef ref, String name) {
  final q = name.trim();
  if (q.isEmpty) return;
  ref.read(pendingSearchProvider.notifier).state = q;
  final cur = ref.read(kotvPageProvider);
  if (cur != KotvPage.search) {
    final stack = List<KotvPage>.from(ref.read(kotvPageStackProvider));
    stack.add(cur);
    while (stack.length > 24) {
      stack.removeAt(0);
    }
    ref.read(kotvPageStackProvider.notifier).state = stack;
  }
  ref.read(kotvPageProvider.notifier).state = KotvPage.search;
}

bool siteIsIndex(WidgetRef ref, String siteKey) {
  final cfg = ref.read(configProvider).valueOrNull;
  final sites = ((cfg?['sites'] as List?) ?? []).whereType<Map>();
  if (siteKey.isNotEmpty) {
    for (final s in sites) {
      if ('${s['key'] ?? ''}' == siteKey) return s['indexs'] == true;
    }
    return false;
  }
  final homeKey = '${cfg?['home'] ?? ''}'.trim();
  for (final s in sites) {
    if (homeKey.isNotEmpty ? '${s['key'] ?? ''}' == homeKey : s['home'] == true) {
      return s['indexs'] == true;
    }
  }
  return false;
}

Future<void>? _vodOpenSerial;

/// 打开列表项：action → 站点 action；folder → 进目录；索引站 → 搜索；否则进详情。
/// [fromFolder] 带 mark 以便详情按文件名选中那一集。
/// [extend] 父级分类筛选，嵌套目录继续带上。
///
/// 串行到路由压上为止。正在看的同一部直接返回；另一部在当前详情里换片。
Future<void> openVodItem(
  BuildContext context,
  WidgetRef ref,
  VodItem item, {
  String? site,
  bool fromFolder = false,
  Map<String, String>? extend,
}) {
  final prev = _vodOpenSerial ?? Future<void>.value();
  final gate = Completer<void>();
  _vodOpenSerial = gate.future;
  void release() {
    if (!gate.isCompleted) gate.complete();
  }

  return prev.catchError((Object _, StackTrace __) {}).then((_) async {
    if (!context.mounted) return;
    try {
      await _openVodItemBody(
        context,
        ref,
        item,
        site: site,
        fromFolder: fromFolder,
        extend: extend,
        release: release,
      );
    } finally {
      release();
    }
  });
}

Future<void> _openVodItemBody(
  BuildContext context,
  WidgetRef ref,
  VodItem item, {
  String? site,
  bool fromFolder = false,
  Map<String, String>? extend,
  required void Function() release,
}) async {
  final siteKey = (site ?? item.site).trim();
  if (item.hasAction) {
    if (!await _gateSharedStorageWrite(context, ref, siteKey, force: true)) return;
    if (!context.mounted) return;
    final api = ref.read(apiProvider);
    try {
      final res = await api.siteAction(site: siteKey, action: item.action);
      if (!context.mounted) return;
      // 网盘授权等会改 jar 磁盘凭证；刷首页登录态文案。
      ref.read(vodContentEpochProvider.notifier).state++;
      final msg = '${res['msg'] ?? ''}'.trim();
      if (msg.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), duration: const Duration(seconds: 4)),
        );
      }
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e')),
      );
    }
    return;
  }
  if (item.isFolder) {
    await kotvStopBackgroundPlayback(keepMini: true);
    if (!context.mounted) return;
    release();
    await Navigator.of(context).push(
      kotvDetailRoute(
        builder: (_) => FolderScreen(
          tid: item.id,
          title: item.name,
          site: siteKey,
          extend: extend == null || extend.isEmpty ? const {} : Map<String, String>.from(extend),
        ),
      ),
    );
    return;
  }
  if (siteIsIndex(ref, siteKey)) {
    await kotvStopBackgroundPlayback(keepMini: true);
    if (!context.mounted) return;
    if (MiniPlayerWindow.active) return;
    searchByName(ref, item.name);
    return;
  }
  final wantSource = item.configSource.trim();
  if (wantSource.isNotEmpty) {
    try {
      final api = ref.read(apiProvider);
      final cfg = await api.getConfig();
      final cur = '${cfg['source'] ?? ''}'.trim();
      if (cur != wantSource) {
        await kotvStopBackgroundPlayback();
        await api.loadConfig(wantSource).timeout(const Duration(seconds: 45));
        ref.invalidate(configProvider);
        ref.invalidate(settingsProvider);
      }
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('切源失败: $e')),
      );
      return;
    }
    if (!context.mounted) return;
  }
  // 仅 api 含 Config 的站弹出系统授权；未授予不进详情。
  if (DetailScreen.isForeground && DetailScreen.matches(item.id, siteKey)) return;
  if (!await _gateSharedStorageWrite(context, ref, siteKey, force: false)) return;
  if (!context.mounted) return;
  Map<String, dynamic> data;
  try {
    data = await ref.read(apiProvider).detail(id: item.id, site: siteKey.isEmpty ? null : siteKey);
  } catch (e) {
    if (await _consumeJarDetailDismissed()) {
      ref.read(vodContentEpochProvider.notifier).state++;
      return;
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    return;
  }
  // jar 在 detailContent 里 finish 了详情层：留在列表，不打开详情页。
  if (await _consumeJarDetailDismissed()) {
    ref.read(vodContentEpochProvider.notifier).state++;
    return;
  }
  if (!context.mounted) return;
  if (DetailScreen.isForeground && DetailScreen.matches(item.id, siteKey)) return;
  final mark = fromFolder ? item.name : '';
  if (DetailScreen.isForeground) {
    await DetailScreen.retarget(
      id: item.id,
      site: siteKey,
      title: item.name,
      mark: mark,
      initialDetail: data,
    );
    return;
  }
  await kotvStopBackgroundPlayback();
  if (!context.mounted) return;
  release();
  await Navigator.of(context).push(
    kotvDetailRoute(
      builder: (_) => DetailScreen(
        id: item.id,
        site: siteKey,
        title: item.name,
        mark: mark,
        initialDetail: data,
      ),
    ),
  );
  // 配置站 detail（网盘授权 / 模式切换等）返回后刷首页。
  ref.read(vodContentEpochProvider.notifier).state++;
}
