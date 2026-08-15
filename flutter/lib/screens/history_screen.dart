import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../nav/kotv_routes.dart';
import '../remote/remote_bridge.dart';
import '../theme/layout_scale.dart';
import '../widgets/chrome.dart';
import '../widgets/poster_card.dart';
import 'detail_screen.dart';
import 'shell.dart';

class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  List<VodItem> _items = [];
  bool _loading = true;
  bool _deleting = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final list = await LocalHistory.list();
    if (!mounted) return;
    setState(() {
      _items = list;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final compact = KotvLayout.isCompact(context) || KotvLayout.useBottomNav(context);
    final land = KotvLayout.isLandscapeCompact(context);
    final pillH = land ? 30.0 : (compact ? 32.0 : 40.0);
    final pillFs = land ? 12.0 : (compact ? 13.0 : 15.0);
    final delW = land ? 72.0 : (compact ? 88.0 : 120.0);
    final clearW = land ? 72.0 : (compact ? 88.0 : 120.0);
    final refreshW = land ? 56.0 : (compact ? 64.0 : 104.0);
    final gap = land ? 6.0 : (compact ? 6.0 : 8.0);
    return Column(
      children: [
        LibraryTopBar(
          onBack: () => kotvPageBack(ref),
          onSearch: () => goKotvPage(ref, KotvPage.search),
          onProfile: () => goKotvPage(ref, KotvPage.profile),
          onNews: () => showAppNews(context, remoteHint(ref)),
          title: '历史',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppPill(
                label: _deleting ? '完成' : (compact ? '删除' : '删除记录'),
                width: delW,
                height: pillH,
                fontSize: pillFs,
                selected: _deleting,
                onTap: () => setState(() => _deleting = !_deleting),
              ),
              SizedBox(width: gap),
              AppPill(
                label: compact ? '清空' : '清空全部',
                width: clearW,
                height: pillH,
                fontSize: pillFs,
                onTap: () async {
                  await LocalHistory.clear();
                  await _reload();
                },
              ),
              if (!compact) ...[
                SizedBox(width: gap),
                AppPill(label: '刷新', width: refreshW, height: pillH, fontSize: pillFs, onTap: _reload),
              ],
            ],
          ),
        ),
        if (_deleting)
          const Padding(
            padding: EdgeInsets.only(bottom: 4),
            child: Text('删除模式：点击海报即可移除', style: TextStyle(color: Color(0xFFCF4274), fontSize: 14)),
          ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator(color: Colors.white))
              : _items.isEmpty
                  ? const Center(child: Text('暂无历史记录', style: TextStyle(color: Colors.white70, fontSize: 18)))
                  : PosterFlow(
                      items: _items,
                      onOpen: (it) async {
                        if (_deleting) {
                          await LocalHistory.remove(it);
                          await _reload();
                          return;
                        }
                        if (!context.mounted) return;
                        Navigator.of(context).push(
                          kotvDetailRoute(
                            builder: (_) => DetailScreen(id: it.id, site: it.site, title: it.name),
                          ),
                        );
                      },
                    ),
        ),
      ],
    );
  }
}
