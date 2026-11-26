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
import '../remote/remote_bridge.dart';
import '../screens/detail_screen.dart';
import '../widgets/auth_gate.dart';
import '../screens/folder_screen.dart';
import '../util/kotv_open_url.dart';

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
Future<bool> _gateSharedStorageWrite(
    BuildContext context, WidgetRef ref, String siteKey,
    {required bool force}) async {
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
Future<bool> kotvConsumeJarDetailDismissed() async {
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
    kotvRememberPage(ref, cur);
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
    if (homeKey.isNotEmpty
        ? '${s['key'] ?? ''}' == homeKey
        : s['home'] == true) {
      return s['indexs'] == true;
    }
  }
  return false;
}

Future<void>? _vodOpenSerial;

/// 推送入口的站点 key：影片 id 即播放地址。配置里若有同名 Push 爬虫，则由它处理。
const kotvPushAgentSite = 'push_agent';

/// 引擎内置的本机文件入口：影片 id 即引擎本机文件路径，不经任何爬虫（下载列表用）。
const kotvLocalFileSite = 'kotv_local_file';

/// 把一个播放地址当影片打开播放（投屏/推送、下载列表里点开已下载文件）。
/// [site] 为空走推送入口；本机文件用 [kotvLocalFileSite]，本机直接读，远端前端由引擎换成 /file/ 地址。
/// 先写 LocalHistory：详情续播读它，带入的进度才能接上。
Future<void> openDirectPlay(
  BuildContext context,
  WidgetRef ref, {
  required String url,
  String site = '',
  String name = '',
  String pic = '',
  String remarks = '',
  String flag = '',
  int positionMs = 0,
}) async {
  final siteKey = site.isEmpty ? kotvPushAgentSite : site;
  final item = VodItem(
    id: url,
    name: name.isEmpty ? url : name,
    pic: pic,
    // push_agent 单集名为「1」，空 remarks 会导致续播匹配失败。
    remarks: remarks.isEmpty ? '1' : remarks,
    site: siteKey,
    flag: flag.isEmpty ? '推送' : flag,
    positionMs: positionMs,
  );
  await LocalHistory.push(item);
  if (!context.mounted) return;
  await openVodItem(context, ref, item, site: siteKey);
}

/// 打开列表项：action → 站点 action；folder → 进目录；索引站可搜；否则进详情。
/// [fromFolder] 带 mark 以便详情按文件名选中那一集。
/// [extend] 父级分类筛选，嵌套目录继续带上。
/// [searchIfIndex] 为 false 时（历史/收藏/继续观看）始终进详情，由详情空结果再精确查找。
///
/// 串行到路由压上为止。正在看的同一部直接返回；另一部在当前详情里换片。
Future<void> openVodItem(
  BuildContext context,
  WidgetRef ref,
  VodItem item, {
  String? site,
  bool fromFolder = false,
  bool searchIfIndex = true,
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
        searchIfIndex: searchIfIndex,
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
  bool searchIfIndex = true,
  Map<String, String>? extend,
  required void Function() release,
}) async {
  final siteKey = (site ?? item.site).trim();
  if (item.hasAction) {
    if (!await _gateSharedStorageWrite(context, ref, siteKey, force: true))
      return;
    if (!context.mounted) return;
    final api = ref.read(apiProvider);
    try {
      final res = await api.siteAction(site: siteKey, action: item.action);
      if (!context.mounted) return;
      // 网盘授权等会改 jar 磁盘凭证；刷首页登录态文案。
      ref.read(vodContentEpochProvider.notifier).state++;
      final web = res['web'];
      final webUrl = web is Map ? '${web['url'] ?? ''}'.trim() : '';
      if (webUrl.isNotEmpty) {
        unawaited(kotvOpenExternalUrl(webUrl));
      }
      final msg = '${res['msg'] ?? ''}'.trim();
      if (msg.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), duration: const Duration(seconds: 4)),
        );
      }
    } catch (e) {
      if (!context.mounted) return;
      if (kotvMessageNeedsLogin(e)) {
        await kotvPresentLoginIfNeeded(context, ref);
        return;
      }
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
          extend: extend == null || extend.isEmpty
              ? const {}
              : Map<String, String>.from(extend),
        ),
      ),
    );
    return;
  }
  if (searchIfIndex && siteIsIndex(ref, siteKey)) {
    await kotvStopBackgroundPlayback(keepMini: true);
    if (!context.mounted) return;
    if (MiniPlayerWindow.active) return;
    searchByName(ref, item.name);
    return;
  }
  final wantSource = item.configSource.trim();
  if (wantSource.isNotEmpty) {
    final api = ref.read(apiProvider);
    try {
      final cfg = await api.getConfig();
      final cur = '${cfg['source'] ?? ''}'.trim();
      if (cur != wantSource) {
        await kotvStopBackgroundPlayback();
        if (!context.mounted) return;
        ref.read(uiBusyProvider.notifier).state = '正在切源…';
        try {
          await api.loadConfig(wantSource).timeout(const Duration(seconds: 45));
          ref.invalidate(configProvider);
          ref.invalidate(settingsProvider);
        } finally {
          ref.read(uiBusyProvider.notifier).state = null;
        }
      }
    } catch (e) {
      ref.read(uiBusyProvider.notifier).state = null;
      if (!context.mounted) return;
      if (kotvMessageNeedsLogin(e)) {
        final ok = await kotvPresentLoginIfNeeded(context, ref);
        if (!ok || !context.mounted) return;
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('切源失败: $e')),
        );
        return;
      }
    }
    if (!context.mounted) return;
  }
  // 仅 api 含 Config 的站弹出系统授权；未授予不进详情。
  if (DetailScreen.isForeground && DetailScreen.matches(item.id, siteKey))
    return;
  if (!await _gateSharedStorageWrite(context, ref, siteKey, force: false))
    return;
  if (!context.mounted) return;
  // 先进详情页再拉详情：点了立刻跳转。jar 在 detailContent 里 finish 详情层由详情页自己出栈。
  final mark = fromFolder ? item.name : '';
  if (DetailScreen.isForeground) {
    await DetailScreen.retarget(
      id: item.id,
      site: siteKey,
      title: item.name,
      mark: mark,
    );
    return;
  }
  // 同源：让出首页/分类 in-flight，不挡 push（与切源 soft cancel 同口径）。
  unawaited(ref.read(apiProvider).cancelPending(hard: false, thunder: false));
  await kotvStopBackgroundPlayback();
  if (!context.mounted) return;
  release();
  final refreshHome =
      siteNeedsSharedWrite(ref, siteKey) || wantSource.isNotEmpty;
  await Navigator.of(context).push(
    kotvDetailRoute(
      builder: (_) => DetailScreen(
        id: item.id,
        site: siteKey,
        title: item.name,
        mark: mark,
      ),
    ),
  );
  // 配置站 detail（网盘授权 / 模式切换等）返回后刷首页。普通影片不重刷。
  if (refreshHome) {
    ref.read(vodContentEpochProvider.notifier).state++;
  }
}
