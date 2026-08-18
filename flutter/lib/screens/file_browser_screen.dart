import 'package:flutter/material.dart';

import '../nav/kotv_routes.dart';
import '../theme/kotv_palette.dart';
import '../theme/kotv_theme.dart';
import '../util/kotv_io.dart';

class _FsItem {
  _FsItem({required this.path, required this.name, required this.isDir});
  final String path;
  final String name;
  final bool isDir;
}

/// 对齐 TV FileActivity：点目录进入，点文件才返回路径。
class FileBrowserScreen extends StatefulWidget {
  const FileBrowserScreen({super.key, required this.root, this.title = '选择文件'});

  final String root;
  final String title;

  static Future<String?> pick(BuildContext context, {required String root, String title = '选择文件'}) {
    return Navigator.of(context, rootNavigator: true).push<String>(
      kotvDetailRoute(builder: (_) => FileBrowserScreen(root: root, title: title)),
    );
  }

  @override
  State<FileBrowserScreen> createState() => _FileBrowserScreenState();
}

class _FileBrowserScreenState extends State<FileBrowserScreen> {
  late String _dir;
  List<_FsItem> _items = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _dir = widget.root;
    _load();
  }

  bool get _isRoot {
    final a = _dir.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
    final b = widget.root.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
    return a == b;
  }

  Future<void> _load() async {
    try {
      final d = Directory(_dir);
      if (!d.existsSync()) {
        setState(() {
          _error = '目录不存在';
          _items = [];
        });
        return;
      }
      final raw = await d.list(followLinks: false).toList();
      final items = <_FsItem>[];
      for (final e in raw) {
        final name = e.path.split(RegExp(r'[/\\]')).last;
        if (name.isEmpty || name == '.' || name == '..') continue;
        items.add(_FsItem(path: e.path, name: name, isDir: FileSystemEntity.isDirectorySync(e.path)));
      }
      items.sort((a, b) {
        if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      if (!mounted) return;
      setState(() {
        _items = items;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _items = [];
      });
    }
  }

  void _enter(_FsItem it) {
    if (it.isDir) {
      setState(() => _dir = it.path);
      _load();
      return;
    }
    Navigator.of(context).pop(it.path);
  }

  void _goUp() {
    if (_isRoot) {
      Navigator.of(context).pop();
      return;
    }
    final parent = Directory(_dir).parent.path;
    setState(() => _dir = parent);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final p = KotvPalette.of(context);
    return PopScope(
      canPop: _isRoot,
      onPopInvoked: (didPop) {
        if (!didPop) _goUp();
      },
      child: Scaffold(
        backgroundColor: p.surface,
        appBar: AppBar(
          backgroundColor: p.surface,
          foregroundColor: p.fg,
          title: Text(widget.title),
          leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: _goUp),
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(_dir, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.muted, fontSize: 13)),
            ),
            Expanded(
              child: _error != null
                  ? Center(child: Text(_error!, textAlign: TextAlign.center))
                  : _items.isEmpty
                      ? const Center(child: Text('空目录'))
                      : ListView.separated(
                          itemCount: _items.length,
                          separatorBuilder: (_, __) => Divider(height: 1, color: p.outline),
                          itemBuilder: (context, i) {
                            final it = _items[i];
                            return TvFocus(
                              autofocus: i == 0,
                              onPressed: () => _enter(it),
                              child: ListTile(
                                leading: Icon(
                                  it.isDir ? Icons.folder_outlined : Icons.insert_drive_file_outlined,
                                  color: p.primary,
                                ),
                                title: Text(it.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                                trailing: it.isDir ? const Icon(Icons.chevron_right) : null,
                                onTap: () => _enter(it),
                              ),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}
