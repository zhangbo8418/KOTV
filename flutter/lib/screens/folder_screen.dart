import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../providers.dart';
import '../theme/layout_scale.dart';
import '../theme/kotv_palette.dart';
import '../theme/kotv_theme.dart';
import '../vod/vod_open.dart';

/// `vod_tag=folder` 用 categoryContent(tid=vod_id) 进目录。
class FolderScreen extends ConsumerStatefulWidget {
  const FolderScreen({
    super.key,
    required this.tid,
    required this.title,
    this.site = '',
  });

  final String tid;
  final String title;
  final String site;

  @override
  ConsumerState<FolderScreen> createState() => _FolderScreenState();
}

class _FolderScreenState extends ConsumerState<FolderScreen> {
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  List<VodItem> _items = [];
  int _page = 1;
  int _pageCount = 1;

  @override
  void initState() {
    super.initState();
    _load(replace: true);
  }

  Future<void> _load({required bool replace}) async {
    if (replace) {
      setState(() {
        _loading = true;
        _error = null;
        _page = 1;
      });
    } else {
      if (_loadingMore || _page >= _pageCount) return;
      setState(() => _loadingMore = true);
    }
    try {
      final pg = replace ? 1 : _page + 1;
      final data = await ref.read(apiProvider).category(
            widget.tid,
            pg: '$pg',
            site: widget.site,
          );
      final list = ((data['list'] as List?) ?? [])
          .whereType<Map>()
          .map((e) => VodItem.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      final pc = (data['pagecount'] is num) ? (data['pagecount'] as num).toInt() : 1;
      if (!mounted) return;
      setState(() {
        _page = pg;
        _pageCount = pc < 1 ? 1 : pc;
        if (replace) {
          _items = list;
        } else {
          _items = [..._items, ...list];
        }
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = LayoutScale.of(context);
    final p = KotvPalette.of(context);
    return Scaffold(
      backgroundColor: p.surface,
      appBar: AppBar(
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
                        if (n.metrics.pixels >= n.metrics.maxScrollExtent - 80) {
                          _load(replace: false);
                        }
                        return false;
                      },
                      child: RefreshIndicator(
                        onRefresh: () => _load(replace: true),
                        child: ListView.separated(
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
                            return TvFocus(
                              onPressed: () => openVodItem(context, ref, it, site: widget.site, fromFolder: true),
                              onLongPress: it.hasAction || it.isFolder ? null : () => searchByName(ref, it.name),
                              child: ListTile(
                                leading: Icon(
                                  it.isFolder ? Icons.folder_outlined : Icons.movie_outlined,
                                  color: p.primary,
                                ),
                                title: Text(it.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                                subtitle: it.remarks.isEmpty ? null : Text(it.remarks),
                                trailing: it.isFolder ? const Icon(Icons.chevron_right) : null,
                                onTap: () => openVodItem(context, ref, it, site: widget.site, fromFolder: true),
                                onLongPress: it.hasAction || it.isFolder ? null : () => searchByName(ref, it.name),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
    );
  }
}
