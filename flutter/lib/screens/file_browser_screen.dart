import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../nav/kotv_routes.dart';
import '../providers.dart';
import '../theme/kotv_palette.dart';
import '../theme/layout_scale.dart';
import '../theme/kotv_theme.dart';
import '../util/kotv_io.dart';

class KotvFsEntry {
  const KotvFsEntry(
      {required this.path, required this.name, required this.isDir});
  final String path;
  final String name;
  final bool isDir;
}

class KotvFsListResult {
  const KotvFsListResult({required this.items, this.parent = ''});
  final List<KotvFsEntry> items;
  final String parent;
}

/// 目录列表回调：返回条目与可返回的父路径（空串表示已到浏览根）。
typedef FsListCallback = Future<KotvFsListResult> Function(String dir);

/// 点目录进入；选文件模式点文件返回路径，选目录模式点「选用此目录」返回当前路径。
class FileBrowserScreen extends ConsumerStatefulWidget {
  const FileBrowserScreen({
    super.key,
    required this.root,
    this.title = '选择文件',
    this.directoryMode = false,
    this.listDir,
  });

  final String root;
  final String title;
  /// true：只浏览文件夹，底部「选用此目录」返回当前路径。
  final bool directoryMode;
  /// 非空时用回调列目录（引擎本机等）；空则读本机文件系统。
  final FsListCallback? listDir;

  static int _open = 0;
  static bool get isOpen => _open > 0;

  static Future<String?> pick(BuildContext context,
      {required String root, String title = '选择文件', FsListCallback? listDir}) {
    return Navigator.of(context, rootNavigator: true).push<String>(
      kotvDetailRoute(
        builder: (_) =>
            FileBrowserScreen(root: root, title: title, listDir: listDir),
      ),
    );
  }

  static Future<String?> pickFolder(
    BuildContext context, {
    required String root,
    String title = '选择目录',
    FsListCallback? listDir,
  }) {
    return Navigator.of(context, rootNavigator: true).push<String>(
      kotvDetailRoute(
        builder: (_) => FileBrowserScreen(
          root: root,
          title: title,
          directoryMode: true,
          listDir: listDir,
        ),
      ),
    );
  }

  @override
  ConsumerState<FileBrowserScreen> createState() => _FileBrowserScreenState();
}

class _FileBrowserScreenState extends ConsumerState<FileBrowserScreen> {
  late String _dir;
  String _parent = '';
  List<KotvFsEntry> _items = [];
  String? _error;
  final _chromeCover = KotvChromeCoverSession();

  @override
  void initState() {
    super.initState();
    FileBrowserScreen._open++;
    _dir = widget.root;
    _chromeCover.holdAfterFrame(
        context, () => mounted, () => ref.read(detailChromeCoverProvider.notifier));
    _load();
  }

  @override
  void dispose() {
    FileBrowserScreen._open--;
    if (FileBrowserScreen._open < 0) FileBrowserScreen._open = 0;
    super.dispose();
  }

  @override
  void activate() {
    super.activate();
    _chromeCover.holdAfterFrame(
        context, () => mounted, () => ref.read(detailChromeCoverProvider.notifier));
  }

  bool get _isRoot {
    final a = _dir.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
    final b = widget.root.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
    return a == b;
  }

  Future<KotvFsListResult> _listLocal(String dir) async {
    if (!kIsWeb && Platform.isAndroid) {
      try {
        const ch = MethodChannel('kotv_android');
        final raw = await ch.invokeMethod<List<dynamic>>('listDir', dir);
        if (raw != null) {
          final items = [
            for (final e in raw)
              if (e is Map)
                KotvFsEntry(
                  path: '${e['path'] ?? ''}',
                  name: '${e['name'] ?? ''}',
                  isDir: e['isDir'] == true,
                ),
          ].where((it) => it.path.isNotEmpty && it.name.isNotEmpty).toList();
          final parent = _isRoot ? '' : Directory(dir).parent.path;
          return KotvFsListResult(items: items, parent: parent);
        }
      } catch (_) {}
    }
    if (kIsWeb) {
      return const KotvFsListResult(items: []);
    }
    final d = Directory(dir);
    if (!d.existsSync()) {
      throw StateError('目录不存在');
    }
    final raw = d.listSync(followLinks: false);
    final items = <KotvFsEntry>[];
    for (final e in raw) {
      final name = e.path.split(RegExp(r'[/\\]')).last;
      if (name.isEmpty || name == '.' || name == '..') continue;
      var isDir = e is Directory;
      if (!isDir) {
        try {
          isDir = FileSystemEntity.isDirectorySync(e.path);
        } catch (_) {}
      }
      items.add(KotvFsEntry(path: e.path, name: name, isDir: isDir));
    }
    final parent = _isRoot ? '' : d.parent.path;
    return KotvFsListResult(items: items, parent: parent);
  }

  Future<void> _load() async {
    try {
      final listed = widget.listDir != null
          ? await widget.listDir!(_dir)
          : await _listLocal(_dir);
      final items = List<KotvFsEntry>.from(listed.items);
      items.sort((a, b) {
        if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      if (!mounted) return;
      setState(() {
        _items = items;
        _parent = listed.parent;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _items = [];
        _parent = '';
      });
    }
  }

  void _enter(KotvFsEntry it) {
    if (it.isDir) {
      setState(() => _dir = it.path);
      _load();
      return;
    }
    if (widget.directoryMode) return;
    Navigator.of(context).pop(it.path);
  }

  void _goUp() {
    if (_isRoot) {
      Navigator.of(context).pop();
      return;
    }
    final parent = _parent.trim();
    if (parent.isEmpty) {
      setState(() => _dir = widget.root);
    } else {
      setState(() => _dir = parent);
    }
    _load();
  }

  bool get _canConfirmDir {
    if (!widget.directoryMode) return false;
    // 根列表（空 path）不能作为落盘目录。
    return _dir.trim().isNotEmpty;
  }

  @override
  Widget build(BuildContext context) {
    final p = KotvPalette.of(context);
    final ui = LayoutScale.grow(context);
    final pathLabel = _dir.trim().isEmpty ? '可浏览位置' : _dir;
    return PopScope(
      canPop: _isRoot,
      onPopInvoked: (didPop) {
        if (didPop) {
          _chromeCover.release(ref.read(detailChromeCoverProvider.notifier));
          return;
        }
        _goUp();
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          toolbarHeight: kToolbarHeight * ui,
          iconTheme: IconThemeData(size: 24 * ui, color: p.fg),
          backgroundColor: p.statusBar,
          foregroundColor: p.fg,
          title: Text(widget.title),
          leading: TvFocus(
            onPressed: _goUp,
            borderRadius: 18,
            autofocus: _items.isEmpty,
            child: ExcludeFocus(
              child: IconButton(
                  icon: const Icon(Icons.arrow_back), onPressed: _goUp),
            ),
          ),
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(pathLabel,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: p.muted, fontSize: 13)),
            ),
            Expanded(
              child: _error != null
                  ? Center(child: Text(_error!, textAlign: TextAlign.center))
                  : () {
                      final items = widget.directoryMode
                          ? _items.where((e) => e.isDir).toList()
                          : _items;
                      if (items.isEmpty) {
                        return Center(
                          child: Text(
                              widget.directoryMode ? '无子文件夹' : '空目录'),
                        );
                      }
                      return ListView.separated(
                        itemCount: items.length,
                        separatorBuilder: (_, __) =>
                            Divider(height: 1, color: p.outline),
                        itemBuilder: (context, i) {
                          final it = items[i];
                          return TvFocus(
                            autofocus: i == 0,
                            onPressed: () => _enter(it),
                            borderRadius: 8,
                            scrollIntoView: true,
                            child: ExcludeFocus(
                              child: ListTile(
                                leading: Icon(
                                  it.isDir
                                      ? Icons.folder_outlined
                                      : Icons.insert_drive_file_outlined,
                                  color: p.primary,
                                ),
                                title: Text(it.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                                trailing: it.isDir
                                    ? const Icon(Icons.chevron_right)
                                    : null,
                                onTap: () => _enter(it),
                              ),
                            ),
                          );
                        },
                      );
                    }(),
            ),
            if (widget.directoryMode)
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: TvFocus(
                    onPressed: _canConfirmDir
                        ? () => Navigator.of(context).pop(_dir)
                        : null,
                    borderRadius: 10,
                    child: Material(
                      color: _canConfirmDir
                          ? p.primary
                          : p.primary.withOpacity(0.35),
                      borderRadius: BorderRadius.circular(10),
                      child: InkWell(
                        onTap: _canConfirmDir
                            ? () => Navigator.of(context).pop(_dir)
                            : null,
                        borderRadius: BorderRadius.circular(10),
                        child: SizedBox(
                          height: 44,
                          child: Center(
                            child: Text(
                              _canConfirmDir ? '选用此目录' : '请进入具体文件夹',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
