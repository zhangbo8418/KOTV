import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../nav/kotv_page.dart';
import '../nav/kotv_routes.dart';
import '../providers.dart';
import '../remote/remote_bridge.dart';
import '../screens/detail_screen.dart';
import '../screens/folder_screen.dart';

/// 对齐 TV TypeFragment 长按 / 索引站：用片名去全网搜索。
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
  for (final s in sites) {
    if (s['home'] == true) return s['indexs'] == true;
  }
  return false;
}

/// 打开列表项：action → 站点 action；folder → 进目录；索引站 → 搜索；否则进详情。
/// [fromFolder] 对齐 TV TypeFragment.isFolder()：带 mark 以便详情按文件名选中那一集。
Future<void> openVodItem(
  BuildContext context,
  WidgetRef ref,
  VodItem item, {
  String? site,
  bool fromFolder = false,
}) async {
  final siteKey = (site ?? item.site).trim();
  if (item.hasAction) {
    final api = ref.read(apiProvider);
    try {
      final res = await api.siteAction(site: siteKey, action: item.action);
      if (!context.mounted) return;
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
    await Navigator.of(context).push(
      kotvDetailRoute(
        builder: (_) => FolderScreen(
          tid: item.id,
          title: item.name,
          site: siteKey,
        ),
      ),
    );
    return;
  }
  if (siteIsIndex(ref, siteKey)) {
    searchByName(ref, item.name);
    return;
  }
  await LocalHistory.push(item);
  if (!context.mounted) return;
  await Navigator.of(context).push(
    kotvDetailRoute(
      builder: (_) => DetailScreen(
        id: item.id,
        site: siteKey,
        title: item.name,
        mark: fromFolder ? item.name : '',
      ),
    ),
  );
}
