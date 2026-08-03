import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../nav/kotv_routes.dart';
import '../remote/remote_bridge.dart';
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
    return Column(
      children: [
        LibraryTopBar(
          onBack: () => goKotvPage(ref, KotvPage.video),
          onSearch: () => goKotvPage(ref, KotvPage.search),
          onProfile: () => goKotvPage(ref, KotvPage.profile),
          onNews: () => showAppNews(context, remoteHint(ref)),
          title: '历史',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppPill(
                label: _deleting ? '完成' : '删除记录',
                width: 120,
                selected: _deleting,
                onTap: () => setState(() => _deleting = !_deleting),
              ),
              const SizedBox(width: 8),
              AppPill(
                label: '清空全部',
                width: 120,
                onTap: () async {
                  await LocalHistory.clear();
                  await _reload();
                },
              ),
              const SizedBox(width: 8),
              AppPill(label: '刷新', width: 104, onTap: _reload),
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
