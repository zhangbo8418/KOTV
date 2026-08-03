import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../nav/kotv_routes.dart';
import '../providers.dart';
import '../remote/remote_bridge.dart';
import '../theme/layout_scale.dart';
import '../theme/kotv_palette.dart';
import '../widgets/chrome.dart';
import '../widgets/poster_card.dart';
import 'detail_screen.dart';
import 'shell.dart';

class _SiteCollect {
  _SiteCollect({required this.name, required this.site, required this.list});
  final String name;
  final String site;
  final List<VodItem> list;
}

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _ctrl = TextEditingController();
  List<_SiteCollect> _collects = [];
  List<String> _hot = List<String>.from(_hotDefaults);
  String? _status;
  bool _busy = false;

  static const _keys = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  static const _hotDefaults = [
    '志愿军', '寻秦记电影版', '好家伙', '放开那个女巫',
    '漫步月球', '独行月球', '流浪地球', '柯南',
  ];

  @override
  void initState() {
    super.initState();
    _loadHot();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final pending = ref.read(pendingSearchProvider);
      if (pending != null && pending.isNotEmpty) {
        _ctrl.text = pending;
        ref.read(pendingSearchProvider.notifier).state = null;
        _search(pending);
      }
    });
  }

  Future<void> _loadHot() async {
    try {
      final st = await ref.read(apiProvider).getSettings();
      final hist = ((st['searchHistory'] as List?) ?? []).map((e) => '$e').where((e) => e.isNotEmpty).toList();
      if (hist.isNotEmpty && mounted) {
        setState(() => _hot = hist.take(12).toList());
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _search(String q) async {
    final kw = q.trim();
    if (kw.isEmpty) return;
    setState(() {
      _busy = true;
      _status = '搜索中…';
      _collects = [];
    });
    try {
      final data = await ref.read(apiProvider).search(kw);
      final collects = <_SiteCollect>[];
      for (final c in ((data['collects'] as List?) ?? []).whereType<Map>()) {
        final name = '${c['name'] ?? ''}';
        if (name == '全部') continue;
        final list = ((c['list'] as List?) ?? [])
            .whereType<Map>()
            .map((e) => VodItem.fromJson(Map<String, dynamic>.from(e)))
            .toList();
        if (list.isEmpty) continue;
        collects.add(_SiteCollect(name: name.isEmpty ? '${c['site'] ?? '站点'}' : name, site: '${c['site'] ?? ''}', list: list));
      }
      // 兼容旧扁平 list
      if (collects.isEmpty) {
        final flat = ((data['list'] as List?) ?? [])
            .whereType<Map>()
            .map((e) => VodItem.fromJson(Map<String, dynamic>.from(e)))
            .toList();
        if (flat.isNotEmpty) {
          collects.add(_SiteCollect(name: '搜索结果', site: '', list: flat));
        }
      }
      final total = collects.fold<int>(0, (a, b) => a + b.list.length);
      setState(() {
        _collects = collects;
        _status = collects.isEmpty ? '无结果' : '找到 $total 条（${collects.length} 个站点）';
      });
      _loadHot();
    } catch (e) {
      setState(() => _status = '$e');
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String?>(pendingSearchProvider, (prev, next) {
      if (next != null && next.isNotEmpty) {
        _ctrl.text = next;
        ref.read(pendingSearchProvider.notifier).state = null;
        _search(next);
      }
    });

    return Column(
      children: [
        LibraryTopBar(
          onBack: () => kotvPageBack(ref),
          onSearch: () => _search(_ctrl.text),
          onProfile: () => goKotvPage(ref, KotvPage.profile),
          onNews: () => showAppNews(context, remoteHint(ref)),
          title: '搜索',
        ),
        Expanded(
          child: Padding(
            padding: EdgeInsets.fromLTRB(KotvLayout.isCompact(context) ? 12 : 24, 0, KotvLayout.isCompact(context) ? 12 : 24, 16),
            child: KotvLayout.useBottomNav(context) || KotvLayout.isCompact(context)
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(height: 168, child: _leftPanel()),
                      const SizedBox(height: 12),
                      Expanded(child: _rightPanel()),
                    ],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: MediaQuery.sizeOf(context).width * 0.34 - 24,
                        child: _leftPanel(),
                      ),
                      const SizedBox(width: 24),
                      Expanded(child: _rightPanel()),
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  Widget _leftPanel() {
    final p = KotvPalette.of(context);
    return ListView(
      children: [
        TextField(
          controller: _ctrl,
          style: TextStyle(color: p.fg),
          decoration: InputDecoration(
            hintText: '请输入要搜索的内容',
            hintStyle: TextStyle(color: p.muted),
          ),
          onSubmitted: _search,
        ),
        const SizedBox(height: 8),
        AppPill(label: _busy ? '…' : '搜索', width: 130, height: 44, selected: true, onTap: _busy ? () {} : () => _search(_ctrl.text)),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: AppPill(
                label: '清空',
                height: 40,
                onTap: () => setState(() {
                  _ctrl.clear();
                  _collects = [];
                  _status = null;
                }),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: AppPill(
                label: '远程搜索',
                height: 40,
                onTap: () => showAppNews(
                  context,
                  '同一局域网内用浏览器打开\nhttp://<本机IP>:${Uri.parse(ref.read(engineLauncherProvider).baseUrl).port}\n即可远程输入关键词',
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        AppPill(
          label: '删除',
          height: 40,
          onTap: () {
            if (_ctrl.text.isEmpty) return;
            final runes = _ctrl.text.runes.toList();
            _ctrl.text = String.fromCharCodes(runes.sublist(0, runes.length - 1));
            _ctrl.selection = TextSelection.collapsed(offset: _ctrl.text.length);
          },
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (var i = 0; i < _keys.length; i++)
              SizedBox(
                width: 44,
                height: 42,
                child: AppPill(
                  label: _keys[i],
                  height: 42,
                  fontSize: 14,
                  onTap: () {
                    _ctrl.text += _keys[i];
                    _ctrl.selection = TextSelection.collapsed(offset: _ctrl.text.length);
                  },
                ),
              ),
          ],
        ),
        if (_status != null) ...[
          const SizedBox(height: 12),
          Text(_status!, style: TextStyle(color: p.muted)),
        ],
      ],
    );
  }

  Widget _rightPanel() {
    final p = KotvPalette.of(context);
    if (_collects.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          color: p.pillBg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: p.pillBorder),
        ),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('热门搜索', style: TextStyle(color: p.fg, fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            for (final h in _hot) ...[
              AppPill(
                label: h,
                width: 220,
                height: 46,
                onTap: () {
                  _ctrl.text = h;
                  _search(h);
                },
              ),
              const SizedBox(height: 8),
            ],
          ],
        ),
      );
    }
    return ListView(
      children: [
        for (final c in _collects) ...[
          SectionTitle(c.name, subtitle: '${c.list.length} 条结果'),
          const SizedBox(height: 8),
          SizedBox(
            height: 300,
            child: PosterFlow(
              items: c.list,
              padding: EdgeInsets.zero,
              onOpen: (it) {
                LocalHistory.push(it);
                Navigator.of(context).push(kotvDetailRoute(
                  builder: (_) => DetailScreen(id: it.id, site: it.site.isNotEmpty ? it.site : c.site, title: it.name),
                ));
              },
            ),
          ),
          const SizedBox(height: 16),
        ],
      ],
    );
  }
}
