import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../remote/local_collect.dart';
import '../widgets/chrome.dart';
import '../widgets/poster_card.dart';
import 'detail_screen.dart';
import 'shell.dart';

class CollectScreen extends ConsumerStatefulWidget {
  const CollectScreen({super.key});

  @override
  ConsumerState<CollectScreen> createState() => _CollectScreenState();
}

class _CollectScreenState extends ConsumerState<CollectScreen> {
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
    final list = await LocalCollect.list();
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
          title: '收藏',
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
                label: '清空收藏',
                width: 120,
                onTap: () async {
                  await LocalCollect.clear();
                  await _reload();
                },
              ),
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
                  ? const Center(child: Text('暂无收藏', style: TextStyle(color: Colors.white70, fontSize: 18)))
                  : PosterFlow(
                      items: _items,
                      padding: const EdgeInsets.fromLTRB(60, 10, 60, 24),
                      onOpen: (it) async {
                        if (_deleting) {
                          await LocalCollect.remove(it);
                          await _reload();
                          return;
                        }
                        if (!context.mounted) return;
                        Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => DetailScreen(id: it.id, site: it.site, title: it.name)),
                        );
                      },
                    ),
        ),
      ],
    );
  }
}
