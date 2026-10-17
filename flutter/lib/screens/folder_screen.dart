import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../providers.dart';
import '../theme/layout_scale.dart';
import '../theme/kotv_palette.dart';
import '../vod/grid_style.dart';
import '../vod/vod_open.dart';
import '../widgets/poster_card.dart';

/// `vod_tag=folder` 用 categoryContent(tid=vod_id) 进目录。
class FolderScreen extends ConsumerStatefulWidget {
  const FolderScreen({
    super.key,
    required this.tid,
    required this.title,
    this.site = '',
    this.extend = const {},
  });

  final String tid;
  final String title;
  final String site;

  /// 父级分类筛选，嵌套目录继续带上。
  final Map<String, String> extend;

  @override
  ConsumerState<FolderScreen> createState() => _FolderScreenState();
}

class _FolderScreenState extends ConsumerState<FolderScreen> {
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  List<VodItem> _items = [];
  int _page = 1;

  /// 0 = 未知总页（靠空列表停）；>0 为明确末页。
  int _pageCount = 0;
  bool _hasMore = true;
  int _autofillStreak = 0;
  KotvGridStyle _style = const KotvGridStyle();
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _load(replace: true);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load({required bool replace, bool fromAutofill = false}) async {
    if (replace) {
      setState(() {
        _loading = true;
        _error = null;
        _page = 1;
        _pageCount = 0;
        _hasMore = true;
        _autofillStreak = 0;
      });
    } else {
      if (_loadingMore || !_hasMore) return;
      if (fromAutofill && _autofillStreak >= 3) return;
      setState(() => _loadingMore = true);
    }
    try {
      final pg = replace ? 1 : _page + 1;
      final data = await ref.read(apiProvider).category(
            widget.tid,
            pg: '$pg',
            site: widget.site,
            extend: widget.extend.isEmpty
                ? null
                : Map<String, String>.from(widget.extend),
          );
      final list = ((data['list'] as List?) ?? [])
          .whereType<Map>()
          .map((e) => VodItem.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      final pcRaw = data['pagecount'];
      final pc = (pcRaw is num) ? pcRaw.toInt() : 0;
      if (!mounted) return;
      // 空页视为末页，避免虚高 pagecount 空刷。
      if (!replace && list.isEmpty) {
        setState(() {
          _hasMore = false;
          _loadingMore = false;
        });
        return;
      }
      setState(() {
        _page = pg;
        if (pc > 0) {
          _pageCount = pc;
        } else if (replace) {
          _pageCount = 0;
        }
        if (replace) {
          _items = list;
          _style = KotvGridStyle.parse(data['style']);
        } else {
          _items = [..._items, ...list];
          if (fromAutofill) {
            _autofillStreak++;
          } else {
            _autofillStreak = 0;
          }
        }
        _hasMore = list.isNotEmpty && (_pageCount == 0 || _page < _pageCount);
        _loading = false;
        _loadingMore = false;
      });
      _scheduleAutofill();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  /// 首屏装不满且还有后续页时自动续载，避免 maxScrollExtent 门槛拦死。
  void _scheduleAutofill() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_hasMore || _loadingMore || _loading) return;
      if (_autofillStreak >= 3) return;
      if (!_scroll.hasClients) return;
      if (_scroll.position.maxScrollExtent > 80) return;
      unawaited(_load(replace: false, fromAutofill: true));
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = LayoutScale.of(context);
    final p = KotvPalette.of(context);
    return Scaffold(
      backgroundColor: p.surface,
      appBar: AppBar(
        toolbarHeight: kToolbarHeight * LayoutScale.growAboveDesign(s),
        iconTheme: IconThemeData(size: 24 * LayoutScale.growAboveDesign(s), color: p.fg),
        title: Text(widget.title.isEmpty ? '目录' : widget.title),
        backgroundColor: p.surface,
        foregroundColor: p.fg,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: EdgeInsets.all(24 * s),
                    child: Text(_error!, textAlign: TextAlign.center),
                  ),
                )
              : _items.isEmpty
                  ? const Center(child: Text('空目录'))
                  : NotificationListener<ScrollNotification>(
                      onNotification: (n) {
                        if (n.metrics.maxScrollExtent > 80 &&
                            n.metrics.pixels >=
                                n.metrics.maxScrollExtent - 80) {
                          _load(replace: false);
                        }
                        return false;
                      },
                      child: RefreshIndicator(
                        onRefresh: () => _load(replace: true),
                        child: _style.isList ? _list(s, p) : _grid(),
                      ),
                    ),
    );
  }

  void _open(VodItem it) {
    openVodItem(
      context,
      ref,
      it,
      site: widget.site,
      fromFolder: true,
      extend: widget.extend,
    );
  }

  Widget _list(double s, KotvPalette p) {
    return ListView.separated(
      controller: _scroll,
      padding: EdgeInsets.symmetric(horizontal: 16 * s, vertical: 8 * s),
      itemCount: _items.length + (_loadingMore ? 1 : 0),
      separatorBuilder: (_, __) => Divider(height: 1, color: p.outline),
      itemBuilder: (context, i) {
        if (i >= _items.length) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final it = _items[i];
        return VodListTile(
          item: it,
          onTap: () => _open(it),
          onLongPress: it.hasAction || it.isFolder
              ? null
              : () => searchByName(ref, it.name),
        );
      },
    );
  }

  Widget _grid() {
    final size = kotvWatchPosterSize(ref);
    return LayoutBuilder(
      builder: (context, c) {
        final pad = KotvLayout.isCompact(context) ? 12.0 : 16.0;
        final m = kotvPosterMetrics(
          context,
          extent: c.maxWidth - pad * 2,
          style: _style,
          size: size,
        );
        return GridView.builder(
          controller: _scroll,
          padding: EdgeInsets.all(pad),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: m.columns,
            mainAxisSpacing: m.gap,
            crossAxisSpacing: m.gap,
            childAspectRatio: m.aspect,
          ),
          itemCount: _items.length + (_loadingMore ? 1 : 0),
          itemBuilder: (context, i) {
            if (i >= _items.length) {
              return const Center(child: CircularProgressIndicator());
            }
            final it = _items[i];
            return PosterCard(
              item: it,
              ratio: _style.ratio,
              oval: _style.isOval,
              onTap: () => _open(it),
              onLongPress: it.hasAction || it.isFolder
                  ? null
                  : () => searchByName(ref, it.name),
            );
          },
        );
      },
    );
  }
}
