import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../remote/download_settings.dart';
import '../remote/local_download.dart';
import '../theme/kotv_palette.dart';
import '../theme/layout_scale.dart';
import '../vod/vod_open.dart';
import '../policy/group_policy.dart';
import '../widgets/chrome.dart';
import '../widgets/h_scroll.dart';
import '../widgets/kotv_network_image.dart';
import '../widgets/kotv_refresh.dart';
import 'shell.dart';

/// 我的下载：状态筛选 → 任务列表；多选时才出批量栏；单项用右侧图标。
class DownloadScreen extends ConsumerStatefulWidget {
  const DownloadScreen({super.key});

  @override
  ConsumerState<DownloadScreen> createState() => _DownloadScreenState();
}

class _DownloadScreenState extends ConsumerState<DownloadScreen> {
  List<Map<String, dynamic>> _tasks = [];
  final _selected = <String>{};
  String _filter = 'all';
  bool _loading = true;
  bool _selectMode = false;
  String? _toast;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _reload();
    _poll =
        Timer.periodic(const Duration(seconds: 1), (_) => _reload(silent: true));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  List<Map<String, dynamic>> get _visible => _tasks
      .where((t) =>
          DownloadSettings.matchFilter('${t['status'] ?? ''}', _filter))
      .toList();

  Future<void> _reload({bool silent = false}) async {
    if (!silent && mounted) setState(() => _loading = true);
    try {
      final list = await LocalDownload.list();
      if (!mounted) return;
      final ids = list.map((e) => '${e['id']}').toSet();
      _selected.removeWhere((id) => !ids.contains(id));
      setState(() {
        _tasks = list;
        _loading = false;
        if (!silent) _toast = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (!silent) _toast = '$e';
      });
    }
  }

  void _setSelectMode(bool on) {
    setState(() {
      _selectMode = on;
      if (!on) _selected.clear();
    });
  }

  void _toggleSelect(String id) {
    setState(() {
      if (_selected.contains(id)) {
        _selected.remove(id);
      } else {
        _selected.add(id);
      }
    });
  }

  Future<void> _runOnIds(
    Iterable<String> ids,
    Future<void> Function(String id) fn, {
    String? okMsg,
    bool leaveSelect = true,
  }) async {
    for (final id in ids) {
      try {
        await fn(id);
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      if (okMsg != null) _toast = okMsg;
      if (leaveSelect) {
        _selected.clear();
        _selectMode = false;
      }
    });
    await _reload();
  }

  Future<void> _actSelected(
      Future<void> Function(String id) fn, String okMsg) async {
    if (_selected.isEmpty) {
      setState(() => _toast = '请先勾选任务');
      return;
    }
    await _runOnIds(_selected.toList(), fn, okMsg: okMsg);
  }

  Future<void> _primaryAction(String id, String status) async {
    if (status == 'running' || status == 'queued') {
      await _runOnIds([id], LocalDownload.pause, leaveSelect: false);
      return;
    }
    if (status == 'paused' || status == 'error' || status == 'cancelled') {
      await _runOnIds([id], LocalDownload.resume, leaveSelect: false);
    }
  }

  Widget _poster(Map<String, dynamic> t, KotvPalette p) {
    final pic = '${t['pic'] ?? ''}'.trim();
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 52,
        height: 72,
        child: pic.isEmpty
            ? ColoredBox(
                color: p.posterPh,
                child: Icon(Icons.movie_outlined, color: p.muted, size: 26),
              )
            : KotvNetworkImage(
                pic,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => ColoredBox(
                  color: p.posterPh,
                  child: Icon(Icons.broken_image_outlined,
                      color: p.muted, size: 22),
                ),
              ),
      ),
    );
  }

  /// 已下载完成：按文件路径直接播放（远端前端由引擎换成 /file/ 地址）。
  Future<void> _playDownloaded(Map<String, dynamic> t) async {
    final path = '${t['path'] ?? ''}'.trim();
    if (path.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('文件路径缺失，无法播放')),
      );
      return;
    }
    await openDirectPlay(
      context,
      ref,
      url: path,
      site: kotvLocalFileSite,
      name: DownloadSettings.taskLabel(t),
      pic: '${t['pic'] ?? ''}'.trim(),
      flag: '本地',
    );
  }

  Widget _iconBtn({
    required IconData icon,
    required String tip,
    required VoidCallback onTap,
    required Color color,
  }) {
    return IconButton(
      tooltip: tip,
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      icon: Icon(icon, size: 22, color: color),
    );
  }

  Widget _bulkBar(KotvPalette p, double s, List<Map<String, dynamic>> visible) {
    return Material(
      color: p.pillBg,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(8 * s, 6, 8 * s, 8),
          child: Row(
            children: [
              TextButton(
                onPressed: () => setState(() {
                  if (_selected.length == visible.length) {
                    _selected.clear();
                  } else {
                    _selected
                      ..clear()
                      ..addAll(visible.map((e) => '${e['id']}'));
                  }
                }),
                child: Text(
                  _selected.length == visible.length && visible.isNotEmpty
                      ? '取消全选'
                      : '全选',
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: () =>
                    _actSelected(LocalDownload.resume, '已开始所选任务'),
                child: const Text('开始'),
              ),
              TextButton(
                onPressed: () =>
                    _actSelected(LocalDownload.pause, '已暂停所选任务'),
                child: const Text('暂停'),
              ),
              TextButton(
                onPressed: () =>
                    _actSelected(LocalDownload.cancel, '已取消所选任务'),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => _actSelected(
                    (id) => LocalDownload.remove(id), '已删除所选任务'),
                child: Text('删除', style: TextStyle(color: p.primary)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _onBack() {
    // 从播放详情叠进来：pop 回详情；从主导航进下载：按 Tab 栈返回。
    final nav = Navigator.of(context);
    if (nav.canPop()) {
      nav.pop();
      return;
    }
    kotvPageBack(ref);
  }

  @override
  Widget build(BuildContext context) {
    final p = KotvPalette.of(context);
    final s = LayoutScale.of(context);
    final hPad = kotvContentInset(context);
    const filterH = 30.0;
    final filterGrow = LayoutScale.grow(context);
    final topAction = LibraryTopBar.actionMetrics(context);
    final visible = _visible;
    final filterIdx =
        DownloadSettings.filterOptions.indexWhere((e) => e.$2 == _filter);
    return Column(
      children: [
        LibraryTopBar(
          title: '我的下载',
          onBack: _onBack,
          onSearch: () => goKotvPage(ref, KotvPage.search),
          onProfile: () => goKotvPage(ref, KotvPage.profile),
          onNews: () => showLatestNews(context, ref),
          trailing: AppPill(
            label: _selectMode ? '完成' : '多选',
            width: topAction.w,
            height: topAction.h,
            fontSize: topAction.fs,
            selected: _selectMode,
            onTap: () => _setSelectMode(!_selectMode),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(hPad, 8 * s, hPad, 0),
          child: SizedBox(
            height: filterH * filterGrow + 4,
            child: HScrollList(
              scrollToIndex: filterIdx >= 0 ? filterIdx : 0,
              itemCount: DownloadSettings.filterOptions.length,
              separatorBuilder: (_, __) => SizedBox(width: 8 * filterGrow),
              itemBuilder: (_, i) {
                final e = DownloadSettings.filterOptions[i];
                return AppPill(
                  label: e.$1,
                  height: filterH,
                  fontSize: 13,
                  growWithWindow: true,
                  selected: _filter == e.$2,
                  onTap: () => setState(() => _filter = e.$2),
                );
              },
            ),
          ),
        ),
        if (_toast != null && _toast!.isNotEmpty)
          Padding(
            padding: EdgeInsets.fromLTRB(hPad, 8 * s, hPad, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(_toast!,
                  style: TextStyle(color: p.muted, fontSize: 13)),
            ),
          ),
        Expanded(
          child: KotvPullRefresh(
            onRefresh: () => _reload(),
            child: _loading && _tasks.isEmpty
              ? kotvPullRefreshFill(
                  const Center(child: CircularProgressIndicator()),
                )
              : visible.isEmpty
                  ? kotvPullRefreshFill(
                      Center(
                        child: Text('暂无下载任务',
                            style: TextStyle(color: p.muted)),
                      ),
                    )
                  : ListView.separated(
                      physics: kotvPullRefreshPhysics,
                      padding: EdgeInsets.fromLTRB(hPad, 12 * s, hPad, 20 * s),
                      itemCount: visible.length,
                      separatorBuilder: (_, __) => SizedBox(height: 10 * s),
                      itemBuilder: (_, i) {
                        final t = visible[i];
                        final id = '${t['id']}';
                        final st = '${t['status'] ?? ''}';
                        final prog = (t['progress'] is num)
                            ? (t['progress'] as num).toDouble().clamp(0.0, 1.0)
                            : 0.0;
                        final on = _selected.contains(id);
                        final canPause = st == 'running' || st == 'queued';
                        final canResume = st == 'paused' ||
                            st == 'error' ||
                            st == 'cancelled';
                        final playable = st == 'done' &&
                            '${t['path'] ?? ''}'.trim().isNotEmpty;
                        return DecoratedBox(
                          decoration: BoxDecoration(
                            color: p.pillBg,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: on ? p.primary : p.pillBorder,
                            ),
                          ),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: _selectMode
                                ? () => _toggleSelect(id)
                                : (playable ? () => _playDownloaded(t) : null),
                            onLongPress: () {
                              _setSelectMode(true);
                              _selected.add(id);
                              setState(() {});
                            },
                            child: Padding(
                              padding:
                                  const EdgeInsets.fromLTRB(12, 12, 8, 12),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  if (_selectMode) ...[
                                    Icon(
                                      on
                                          ? Icons.check_circle
                                          : Icons.circle_outlined,
                                      color: on ? p.primary : p.muted,
                                      size: 22,
                                    ),
                                    const SizedBox(width: 8),
                                  ],
                                  _poster(t, p),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        Text(
                                          DownloadSettings.taskLabel(t),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: p.fg,
                                            fontSize: 14,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          DownloadSettings.statusLabel(t),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                              color: p.muted, fontSize: 12),
                                        ),
                                        if (st == 'running' ||
                                            (st == 'paused' && prog > 0)) ...[
                                          const SizedBox(height: 8),
                                          ClipRRect(
                                            borderRadius:
                                                BorderRadius.circular(4),
                                            child: LinearProgressIndicator(
                                              value: prog > 0 ? prog : null,
                                              minHeight: 3,
                                              backgroundColor:
                                                  p.fg.withOpacity(0.08),
                                              color: p.primary,
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  if (!_selectMode) ...[
                                    if (playable)
                                      _iconBtn(
                                        icon: Icons.play_circle_fill,
                                        tip: '播放',
                                        color: p.primary,
                                        onTap: () => _playDownloaded(t),
                                      ),
                                    if (canPause || canResume)
                                      _iconBtn(
                                        icon: canPause
                                            ? Icons.pause_circle_outline
                                            : Icons.play_circle_outline,
                                        tip: canPause ? '暂停' : '开始',
                                        color: p.fg,
                                        onTap: () =>
                                            _primaryAction(id, st),
                                      ),
                                    PopupMenuButton<String>(
                                      tooltip: '更多',
                                      padding: EdgeInsets.zero,
                                      icon: Icon(Icons.more_vert,
                                          color: p.muted, size: 22),
                                      onSelected: (v) async {
                                        if (v == 'cancel') {
                                          await _runOnIds([id],
                                              LocalDownload.cancel,
                                              leaveSelect: false);
                                        } else if (v == 'delete') {
                                          await _runOnIds(
                                              [id],
                                              (x) => LocalDownload.remove(x),
                                              leaveSelect: false);
                                        }
                                      },
                                      itemBuilder: (_) => [
                                        if (st == 'running' ||
                                            st == 'queued' ||
                                            st == 'paused')
                                          const PopupMenuItem(
                                            value: 'cancel',
                                            child: Text('取消任务'),
                                          ),
                                        const PopupMenuItem(
                                          value: 'delete',
                                          child: Text('删除记录'),
                                        ),
                                      ],
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
          ),
        ),
        if (_selectMode) _bulkBar(p, s, visible),
      ],
    );
  }
}
