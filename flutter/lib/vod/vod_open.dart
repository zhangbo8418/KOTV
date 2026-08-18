import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../nav/kotv_routes.dart';
import '../providers.dart';
import '../remote/remote_bridge.dart';
import '../screens/detail_screen.dart';

/// 打开列表项：带 action 时走 TV 式站点 action，否则进详情。
Future<void> openVodItem(
  BuildContext context,
  WidgetRef ref,
  VodItem item, {
  String? site,
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
  await LocalHistory.push(item);
  if (!context.mounted) return;
  await Navigator.of(context).push(
    kotvDetailRoute(
      builder: (_) => DetailScreen(
        id: item.id,
        site: siteKey,
        title: item.name,
      ),
    ),
  );
}
