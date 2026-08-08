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
  int _searchGen = 0;
  int _doneSites = 0;
  int _totalSites = 0;

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
    _searchGen++;
    _ctrl.dispose();
    super.dispose();
  }

  List<_SiteCollect> _parseCollects(Map<String, dynamic> data) {
    final collects = <_SiteCollect>[];
    for (final c in ((data['collects'] as List?) ?? []).whereType<Map>()) {
      final name = '${c['name'] ?? ''}';
      if (name == '全部') continue;
      final list = ((c['list'] as List?) ?? [])
          .whereType<Map>()
          .map((e) => VodItem.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      if (list.isEmpty) continue;
      collects.add(_SiteCollect(
        name: name.isEmpty ? '${c['site'] ?? '站点'}' : name,
        site: '${c['site'] ?? ''}',
        list: list,
      ));
    }
    if (collects.isEmpty) {
      final flat = ((data['list'] as List?) ?? [])
          .whereType<Map>()
          .map((e) => VodItem.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      if (flat.isNotEmpty) {
        collects.add(_SiteCollect(name: '搜索结果', site: '', list: flat));
      }
    }
    return collects;
  }

  int get _hitCount => _collects.fold<int>(0, (a, b) => a + b.list.length);

  void _appendCollects(List<_SiteCollect> next) {
    if (next.isEmpty) return;
    final merged = List<_SiteCollect>.from(_collects);
    for (final c in next) {
      final i = merged.indexWhere((e) => e.site == c.site && e.site.isNotEmpty);
      if (i >= 0) {
        final old = merged[i];
        final seen = old.list.map((e) => e.id).toSet();
        merged[i] = _SiteCollect(
          name: old.name,
          site: old.site,
          list: [...old.list, ...c.list.where((e) => !seen.contains(e.id))],
        );
      } else {
        merged.add(c);
      }
    }
    _collects = merged;
  }

  Future<void> _search(String q) async {
    final kw = q.trim();
    if (kw.isEmpty) return;
    final gen = ++_searchGen;
    setState(() {
      _busy = true;
      _status = '搜索中…';
      _collects = [];
      _doneSites = 0;
      _totalSites = 0;
    });

    try {
      final cfg = await ref.read(apiProvider).getConfig();
      if (!mounted || gen != _searchGen) return;
      final sites = ((cfg['sites'] as List?) ?? [])
          .whereType<Map>()
          .map((e) => SiteInfo.fromJson(Map<String, dynamic>.from(e)))
          .where((s) => s.searchable && s.key.isNotEmpty)
          .toList();

      if (sites.isEmpty) {
        final data = await ref.read(apiProvider).search(kw);
        if (!mounted || gen != _searchGen) return;
        final collects = _parseCollects(data);
        setState(() {
          _collects = collects;
          _status = collects.isEmpty ? '无结果' : '找到 ${_hitCount} 条';
        });
        _loadHot();
        return;
      }

      setState(() {
        _totalSites = sites.length;
        _status = '搜索中 0/${sites.length}';
      });

      var cursor = 0;
      Future<void> worker() async {
        while (true) {
          final i = cursor++;
          if (i >= sites.length) return;
          if (!mounted || gen != _searchGen) return;
          final site = sites[i];
          try {
            final data = await ref.read(apiProvider).search(kw, sites: [site.key]);
            if (!mounted || gen != _searchGen) return;
            final got = _parseCollects(data);
            setState(() {
              _appendCollects(got);
              _doneSites++;
              final hits = _hitCount;
              _status = _doneSites >= _totalSites
                  ? (hits == 0 ? '无结果' : '找到 $hits 条（${_collects.length} 个站点）')
                  : '搜索中 $_doneSites/$_totalSites · 已找到 $hits 条';
            });
          } catch (_) {
            if (!mounted || gen != _searchGen) return;
            setState(() {
              _doneSites++;
              final hits = _hitCount;
              _status = _doneSites >= _totalSites
                  ? (hits == 0 ? '无结果' : '找到 $hits 条（${_collects.length} 个站点）')
                  : '搜索中 $_doneSites/$_totalSites · 已找到 $hits 条';
            });
          }
        }
      }

      const workers = 4;
      await Future.wait(List.generate(workers, (_) => worker()));
      if (!mounted || gen != _searchGen) return;
      final hits = _hitCount;
      setState(() {
        _status = hits == 0 ? '无结果' : '找到 $hits 条（${_collects.length} 个站点）';
      });
      _loadHot();
    } catch (e) {
      if (!mounted || gen != _searchGen) return;
      setState(() => _status = '$e');
    } finally {
      if (mounted && gen == _searchGen) {
        setState(() => _busy = false);
      }
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
        AppPill(
          label: _busy ? '搜索中' : '搜索',
          width: 130,
          height: 44,
          selected: true,
          onTap: _busy ? () {} : () => _search(_ctrl.text),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: AppPill(
                label: '清空',
                height: 40,
                onTap: () {
                  _searchGen++;
                  setState(() {
                    _ctrl.clear();
                    _collects = [];
                    _status = null;
                    _busy = false;
                    _doneSites = 0;
                    _totalSites = 0;
                  });
                },
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
    final showHot = _collects.isEmpty && !_busy;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (showHot)
          _hotPanel(p)
        else if (_collects.isEmpty)
          Container(
            decoration: BoxDecoration(
              color: p.pillBg,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: p.pillBorder),
            ),
          )
        else
          _resultsList(),
        if (_busy && _collects.isEmpty)
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0x66000000),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 280),
                  child: Material(
                    color: const Color(0xCC1A1228),
                    borderRadius: BorderRadius.circular(14),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(
                            width: 28,
                            height: 28,
                            child: CircularProgressIndicator(strokeWidth: 2.6, color: Colors.white),
                          ),
                          const SizedBox(height: 14),
                          const Text(
                            '正在搜索…',
                            style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _totalSites > 0
                                ? '$_doneSites / $_totalSites 站点 · 已找到 $_hitCount 条'
                                : (_status ?? ''),
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white.withOpacity(0.75), fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          )
        else if (_busy && _collects.isNotEmpty)
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: Material(
              color: const Color(0xCC1A1228),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '继续搜索 $_doneSites/$_totalSites · 已找到 $_hitCount 条',
                        style: TextStyle(color: Colors.white.withOpacity(0.9), fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _hotPanel(KotvPalette p) {
    return Container(
      decoration: BoxDecoration(
        color: p.pillBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: p.pillBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Text('热门搜索', style: TextStyle(color: p.fg, fontSize: 20, fontWeight: FontWeight.w700)),
          ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
              itemCount: _hot.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (_, i) {
                final h = _hot[i];
                return Align(
                  alignment: Alignment.centerLeft,
                  child: AppPill(
                    label: h,
                    width: 220,
                    height: 46,
                    onTap: () {
                      _ctrl.text = h;
                      _search(h);
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _resultsList() {
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
