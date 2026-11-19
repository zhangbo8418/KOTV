import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../providers.dart';
import '../remote/engine_tools.dart';
import '../theme/kotv_palette.dart';
import '../widgets/chrome.dart';

/// 服务端分组策略（settings/config 的 policy 字段）。
class GroupPolicy {
  const GroupPolicy({
    this.groupId = 'default',
    this.caps = const {},
    this.notices = const [],
    this.maintenance = false,
    this.maintenanceMsg = '',
    this.forceUpdate = false,
    this.minClientVersion = '',
    this.updateUrl = '',
    this.brand = const {},
  });

  final String groupId;
  final Map<String, bool> caps;
  final List<Map<String, dynamic>> notices;
  final bool maintenance;
  final String maintenanceMsg;
  final bool forceUpdate;
  final String minClientVersion;
  final String updateUrl;
  final Map<String, String> brand;

  static const empty = GroupPolicy();

  bool cap(String key, {bool fallback = true}) => caps[key] ?? fallback;

  /// 品牌字段（分组优先、全局回落已由服务端 Resolve）。
  String brandOf(String key) => (brand[key] ?? '').trim();

  factory GroupPolicy.fromJson(Map<String, dynamic>? raw) {
    if (raw == null || raw.isEmpty) return empty;
    final capsRaw = raw['caps'];
    final caps = <String, bool>{};
    if (capsRaw is Map) {
      capsRaw.forEach((k, v) {
        if (v is bool) {
          caps['$k'] = v;
        } else {
          final s = '$v'.trim().toLowerCase();
          caps['$k'] = s == '1' || s == 'true' || s == 'yes' || s == 'on';
        }
      });
    }
    final notices = <Map<String, dynamic>>[];
    final n = raw['notices'];
    if (n is List) {
      for (final e in n) {
        if (e is Map) notices.add(Map<String, dynamic>.from(e));
      }
    }
    final brand = <String, String>{};
    final b = raw['brand'];
    if (b is Map) {
      b.forEach((k, v) {
        final s = '$v'.trim();
        if (s.isNotEmpty) brand['$k'] = s;
      });
    }
    return GroupPolicy(
      groupId: '${raw['groupId'] ?? 'default'}',
      caps: caps,
      notices: notices,
      maintenance: raw['maintenance'] == true,
      maintenanceMsg: '${raw['maintenanceMsg'] ?? ''}',
      forceUpdate: raw['forceUpdate'] == true,
      minClientVersion: '${raw['minClientVersion'] ?? ''}',
      updateUrl: '${raw['updateUrl'] ?? ''}',
      brand: brand,
    );
  }
}

final groupPolicyProvider = Provider<GroupPolicy>((ref) {
  final cfg = ref.watch(configProvider);
  return cfg.maybeWhen(
    data: (d) => GroupPolicy.fromJson(
      Map<String, dynamic>.from((d['policy'] as Map?) ?? const {}),
    ),
    orElse: () {
      final st = ref.watch(settingsProvider);
      return st.maybeWhen(
        data: (d) => GroupPolicy.fromJson(
          Map<String, dynamic>.from((d['policy'] as Map?) ?? const {}),
        ),
        orElse: () => GroupPolicy.empty,
      );
    },
  );
});

/// 比较 semver 粗略：a < b → -1。
int kotvCompareVersion(String a, String b) {
  List<int> parts(String s) => s
      .split(RegExp(r'[^0-9]+'))
      .where((e) => e.isNotEmpty)
      .map((e) => int.tryParse(e) ?? 0)
      .toList();
  final pa = parts(a);
  final pb = parts(b);
  final n = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < n; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x < y ? -1 : 1;
  }
  return 0;
}

Future<bool> _openExternalUrl(String raw) async {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
    return false;
  }
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// 关于：只展示管理端品牌配置（aboutUrl / welcome / support / footer）。
/// 与「运行库」分离；未配置时提示去管理台填写。
Future<void> showKotvAbout(BuildContext context, WidgetRef ref) async {
  if (!context.mounted) return;
  final pol = ref.read(groupPolicyProvider);
  final aboutUrl = pol.brandOf('aboutUrl');
  final welcome = pol.brandOf('welcome');
  final footer = pol.brandOf('footer');
  final support = pol.brandOf('supportUrl');

  if (aboutUrl.isNotEmpty && welcome.isEmpty && footer.isEmpty && support.isEmpty) {
    final ok = await _openExternalUrl(aboutUrl);
    if (!context.mounted) return;
    if (ok) return;
    showAppNews(context, '无法打开关于页\n$aboutUrl');
    return;
  }

  final lines = <String>[];
  if (welcome.isNotEmpty) lines.add(welcome);
  if (support.isNotEmpty) lines.add('支持：$support');
  if (aboutUrl.isNotEmpty) lines.add('详情：$aboutUrl');
  if (footer.isNotEmpty) {
    if (lines.isNotEmpty) lines.add('');
    lines.add(footer);
  }
  if (lines.isEmpty) {
    showAppNews(context, '暂无关于信息\n请在管理控制台「全局设置 → 品牌」配置');
    return;
  }

  final p = KotvPalette.of(context);
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: p.dialogBg,
      title: Text('关于', style: TextStyle(color: p.fg)),
      content: SingleChildScrollView(
        child: Text(lines.join('\n'), style: TextStyle(color: p.muted)),
      ),
      actions: [
        if (aboutUrl.isNotEmpty)
          KotvFocusAction(
            label: '打开链接',
            color: p.focus,
            onPressed: () => _openExternalUrl(aboutUrl),
          ),
        KotvFocusAction(
          label: '关闭',
          color: p.primary,
          autofocus: true,
          onPressed: () => Navigator.pop(ctx),
        ),
      ],
    ),
  );
}

/// 检查更新（设置 / 我的 共用）；返回展示文案。
Future<String> kotvCheckUpdate(WidgetRef ref) async {
  final data = await ref.read(apiProvider).tools('checkUpdate');
  return kotvFormatCheckUpdateResult(data);
}

Future<void> kotvCheckUpdateAndShow(BuildContext context, WidgetRef ref) async {
  try {
    final msg = await kotvCheckUpdate(ref);
    if (context.mounted) showAppNews(context, msg);
  } catch (e) {
    if (context.mounted) showAppNews(context, '检查失败: $e');
  }
}

/// 顶栏「最新消息」：展示当前策略下的公告。
Future<void> showLatestNews(BuildContext context, WidgetRef ref) async {
  if (!context.mounted) return;
  final notices = ref.read(groupPolicyProvider).notices;
  if (notices.isEmpty) {
    showAppNews(context, '暂无最新消息');
    return;
  }
  if (notices.length == 1) {
    await _showNoticeDetail(context, ref, notices.first);
    return;
  }
  final p = KotvPalette.of(context);
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: p.dialogBg,
      title: Text('最新消息', style: TextStyle(color: p.fg)),
      content: SizedBox(
        width: 420,
        child: ListView.separated(
          shrinkWrap: true,
          itemCount: notices.length,
          separatorBuilder: (_, __) => Divider(height: 1, color: p.pillBorder),
          itemBuilder: (_, i) {
            final n = notices[i];
            final title = '${n['title'] ?? ''}'.trim();
            final body = '${n['body'] ?? ''}'.trim();
            final sticky = n['sticky'] == true;
            return ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                title.isEmpty ? '公告' : title,
                style: TextStyle(color: p.fg, fontWeight: FontWeight.w600),
              ),
              subtitle: body.isEmpty
                  ? null
                  : Text(
                      body,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: p.muted, fontSize: 13),
                    ),
              trailing: sticky
                  ? Text('需确认', style: TextStyle(color: p.focus, fontSize: 12))
                  : null,
              onTap: () async {
                Navigator.pop(ctx);
                if (context.mounted) {
                  await _showNoticeDetail(context, ref, n);
                }
              },
            );
          },
        ),
      ),
      actions: [
        KotvFocusAction(
          label: '关闭',
          color: p.primary,
          autofocus: true,
          onPressed: () => Navigator.pop(ctx),
        ),
      ],
    ),
  );
}

Future<void> _showNoticeDetail(
  BuildContext context,
  WidgetRef ref,
  Map<String, dynamic> n,
) async {
  if (!context.mounted) return;
  final p = KotvPalette.of(context);
  final title = '${n['title'] ?? ''}'.trim();
  final body = '${n['body'] ?? ''}'.trim();
  final link = '${n['link'] ?? ''}'.trim();
  final sticky = n['sticky'] == true;
  final id = '${n['id'] ?? ''}';
  await showDialog<void>(
    context: context,
    barrierDismissible: !sticky,
    builder: (ctx) => AlertDialog(
      backgroundColor: p.dialogBg,
      title: Text(title.isEmpty ? '公告' : title, style: TextStyle(color: p.fg)),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              body.isEmpty ? '（无正文）' : body,
              style: TextStyle(color: p.muted),
            ),
            if (link.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(link, style: TextStyle(color: p.focus, fontSize: 13)),
            ],
          ],
        ),
      ),
      actions: [
        if (link.isNotEmpty)
          KotvFocusAction(
            label: '打开链接',
            color: p.focus,
            onPressed: () => _openExternalUrl(link),
          ),
        KotvFocusAction(
          label: sticky ? '已知晓' : '关闭',
          color: p.primary,
          autofocus: true,
          onPressed: () async {
            Navigator.pop(ctx);
            if (sticky && id.isNotEmpty) {
              try {
                await ref.read(apiProvider).ackNotice(id);
              } catch (e) {
                debugPrint('notice ack: $e');
              }
            }
          },
        ),
      ],
    ),
  );
}

/// 展示公告/维护/强更；sticky 点确认后 ack。
Future<void> kotvApplyGroupPolicyUI(
  BuildContext context,
  WidgetRef ref,
  GroupPolicy pol, {
  required String clientVersion,
}) async {
  if (!context.mounted) return;
  if (pol.maintenance) {
    final msg = pol.maintenanceMsg.trim().isEmpty ? '系统维护中' : pol.maintenanceMsg;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('维护中'),
        content: Text(msg),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了')),
        ],
      ),
    );
  }
  if (pol.forceUpdate &&
      pol.minClientVersion.trim().isNotEmpty &&
      kotvCompareVersion(clientVersion, pol.minClientVersion) < 0) {
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('需要更新'),
        content: Text('当前版本过旧，请升级到 ${pol.minClientVersion} 或更高。'),
        actions: [
          if (pol.updateUrl.trim().isNotEmpty)
            TextButton(
              onPressed: () async {
                await _openExternalUrl(pol.updateUrl);
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('前往更新'),
            ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了')),
        ],
      ),
    );
  }
  for (final n in pol.notices) {
    if (!context.mounted) return;
    final kind = '${n['kind'] ?? 'banner'}';
    final title = '${n['title'] ?? ''}';
    final body = '${n['body'] ?? ''}';
    final sticky = n['sticky'] == true;
    final id = '${n['id'] ?? ''}';
    final link = '${n['link'] ?? ''}'.trim();
    if (kind == 'toast') {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(title.isEmpty ? body : '$title\n$body')),
      );
      continue;
    }
    await showDialog<void>(
      context: context,
      barrierDismissible: !sticky,
      builder: (ctx) => AlertDialog(
        title: Text(title.isEmpty ? '公告' : title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(body),
            if (link.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(link, style: const TextStyle(fontSize: 13)),
            ],
          ],
        ),
        actions: [
          if (link.isNotEmpty)
            TextButton(
              onPressed: () => _openExternalUrl(link),
              child: const Text('打开链接'),
            ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              if (sticky && id.isNotEmpty) {
                try {
                  await ref.read(apiProvider).ackNotice(id);
                } catch (e) {
                  debugPrint('notice ack: $e');
                }
              }
            },
            child: Text(sticky ? '已知晓' : '关闭'),
          ),
        ],
      ),
    );
  }
}
