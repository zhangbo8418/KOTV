import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/kotv_api.dart';

/// 对齐 Legacy [listenSpiderPostMsg]：轮询引擎缓冲，只渲染声明式文档（内容/尺寸由 jar·js·py 决定）。
///
/// 网盘登录会先发「正在获取…」再发真正二维码（两个不同 id）。
/// 这里用**同一条 Dialog 路由原地换文档**，避免 pop+show 时把新窗一起关掉。
class PostMsgHost {
  PostMsgHost(this.api, {required this.navigatorKey});

  /// 当前活跃宿主（详情页返回时用来关掉网盘扫码窗并回传 cancel）。
  static PostMsgHost? instance;

  final KotvApi api;
  final GlobalKey<NavigatorState> navigatorKey;

  Timer? _timer;
  Timer? _timeout;
  bool _dialogOpen = false;
  bool _programmaticClose = false;
  String? _activeId;
  final ValueNotifier<Map<String, dynamic>?> _doc = ValueNotifier(null);
  Completer<void>? _dialogDone;

  String _lastToast = '';
  DateTime _lastToastAt = DateTime.fromMillisecondsSinceEpoch(0);

  void start() {
    instance = this;
    _timer?.cancel();
    unawaited(_tick());
    _timer = Timer.periodic(const Duration(milliseconds: 120), (_) => _tick());
  }

  void stop() {
    if (instance == this) instance = null;
    _timer?.cancel();
    _timer = null;
    unawaited(cancelAll(reply: true));
  }

  /// 关掉当前声明式窗，并向引擎回传 dismiss，避免 JAR 登录循环空等。
  Future<void> cancelAll({bool reply = true}) async {
    final id = _activeId;
    if (reply && id != null && id.isNotEmpty) {
      unawaited(api.uiReply(id: id, action: 'dismiss'));
    }
    await _hide(reply: false);
  }

  Future<void> _tick() async {
    try {
      final data = await api.uiPoll();
      final msgs = (data['messages'] as List?) ?? const [];
      for (final raw in msgs) {
        _handle('${raw ?? ''}');
      }
    } catch (_) {}
  }

  void _handle(String raw) {
    final msg = raw.trim();
    if (msg.isEmpty) return;

    if (msg.startsWith('UI:')) {
      final payload = msg.substring(3);
      try {
        final doc = jsonDecode(payload);
        if (doc is Map<String, dynamic> && '${doc['id'] ?? ''}'.isNotEmpty) {
          _showOrReplace(Map<String, dynamic>.from(doc));
        }
      } catch (_) {}
      return;
    }

    if (msg.startsWith('UI_CLOSE:')) {
      try {
        final cmd = jsonDecode(msg.substring(9));
        if (cmd is Map && '${cmd['id'] ?? ''}'.isNotEmpty) {
          _close('${cmd['id']}');
        }
      } catch (_) {}
      return;
    }

    final now = DateTime.now();
    if (msg == _lastToast && now.difference(_lastToastAt) < const Duration(milliseconds: 800)) {
      return;
    }
    _lastToast = msg;
    _lastToastAt = now;
    final ctx = navigatorKey.currentContext;
    if (ctx == null) return;
    ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }

  void _showOrReplace(Map<String, dynamic> doc) {
    final id = '${doc['id']}'.trim();
    if (id.isEmpty) return;

    final prev = _activeId;
    _activeId = id;
    _armTimeout(doc);

    // 已有弹窗：原地换内容（加载 → 二维码），绝不 pop 再 show。
    if (_dialogOpen) {
      _doc.value = doc;
      return;
    }

    final ctx = navigatorKey.currentContext;
    if (ctx == null) {
      // 无 context 时也必须回传，否则 JAR 端会一直占着 JVM 线程。
      unawaited(api.uiReply(id: id, action: 'dismiss'));
      _activeId = prev;
      _timeout?.cancel();
      return;
    }

    _doc.value = doc;
    _dialogOpen = true;
    _programmaticClose = false;
    final done = Completer<void>();
    _dialogDone = done;
    unawaited(_openDialog(ctx, done));
  }

  void _armTimeout(Map<String, dynamic> doc) {
    _timeout?.cancel();
    final timeoutMs = (doc['timeoutMs'] is num) ? (doc['timeoutMs'] as num).toInt() : 0;
    if (timeoutMs <= 0) return;
    final id = '${doc['id']}';
    _timeout = Timer(Duration(milliseconds: timeoutMs), () {
      if (_activeId != id) return;
      unawaited(api.uiReply(id: id, action: 'timeout'));
      unawaited(_hide(reply: false));
    });
  }

  void _close(String id) {
    // 关键：加载窗的 UI_CLOSE 常在二维码 UI: 之后才到；
    // 若当前已经是新 id，必须忽略旧 CLOSE，否则会把二维码一起关掉。
    if (_activeId != id) return;
    unawaited(_hide(reply: false));
  }

  Future<void> _hide({required bool reply}) async {
    _timeout?.cancel();
    _timeout = null;
    final id = _activeId;
    if (reply && id != null && id.isNotEmpty) {
      unawaited(api.uiReply(id: id, action: 'dismiss'));
    }
    _activeId = null;
    _doc.value = null;
    if (!_dialogOpen) {
      _dialogDone?.complete();
      _dialogDone = null;
      return;
    }
    _programmaticClose = true;
    final nav = navigatorKey.currentState;
    // 只在 Dialog 仍在栈顶时 pop，避免误 pop 详情页。
    if (nav != null && nav.canPop()) {
      nav.pop();
    }
    final done = _dialogDone;
    if (done != null && !done.isCompleted) {
      done.complete();
    }
  }

  Future<void> _openDialog(BuildContext ctx, Completer<void> done) async {
    final values = <String, TextEditingController>{};
    final checks = <String, bool>{};
    final radios = <String, String>{};
    final selects = <String, String>{};

    try {
      await showDialog<void>(
        context: ctx,
        // 禁止点遮罩误关：加载→二维码切换时旧点击/动画容易误触 barrier。
        barrierDismissible: false,
        builder: (dialogCtx) {
          return PopScope(
            canPop: true,
            onPopInvoked: (didPop) {
              if (!didPop) return;
              if (!_programmaticClose && _activeId != null) {
                unawaited(api.uiReply(id: _activeId!, action: 'dismiss'));
              }
              _activeId = null;
              _timeout?.cancel();
              _doc.value = null;
              _dialogOpen = false;
              if (!done.isCompleted) done.complete();
            },
            child: ValueListenableBuilder<Map<String, dynamic>?>(
              valueListenable: _doc,
              builder: (ctx, doc, _) {
                if (doc == null) {
                  return const SizedBox.shrink();
                }
                return StatefulBuilder(
                  builder: (ctx, setLocal) {
                    Map<String, String> collect() {
                      final out = <String, String>{};
                      for (final e in values.entries) {
                        out[e.key] = e.value.text;
                      }
                      for (final e in checks.entries) {
                        out[e.key] = e.value ? 'true' : 'false';
                      }
                      out.addAll(radios);
                      out.addAll(selects);
                      return out;
                    }

                    Future<void> fire(String action, {bool dismissAfter = false}) async {
                      final id = '${doc['id']}';
                      await api.uiReply(id: id, action: action, values: collect());
                      if (dismissAfter) {
                        await _hide(reply: false);
                      }
                    }

                    // 换文档时清掉旧输入，避免加载窗控件残留到二维码窗。
                    // 仅在 id 变化时重置（ValueListenable 每次 build 都会进这里）。
                    final title = '${doc['title'] ?? ''}';
                    final elements = (doc['elements'] as List?) ?? const [];
                    final actions = (doc['actions'] as List?) ?? const [];
                    final width = (doc['width'] is num) ? (doc['width'] as num).toDouble() : 420.0;
                    final height = (doc['height'] is num) ? (doc['height'] as num).toDouble() : 480.0;

                    return AlertDialog(
                      backgroundColor: const Color(0xFF1A1028),
                      title: title.isEmpty
                          ? null
                          : Text(title, style: const TextStyle(color: Colors.white)),
                      content: SizedBox(
                        width: width.clamp(200, 900),
                        height: height.clamp(120, 900),
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (final el in elements)
                                if (el is Map)
                                  ..._buildElement(
                                    Map<String, dynamic>.from(el),
                                    values: values,
                                    checks: checks,
                                    radios: radios,
                                    selects: selects,
                                    setLocal: setLocal,
                                    fire: fire,
                                  ),
                            ],
                          ),
                        ),
                      ),
                      actions: [
                        for (final a in actions)
                          if (a is Map)
                            TextButton(
                              onPressed: () => fire(
                                '${a['id'] ?? 'action'}',
                                dismissAfter: a['dismiss'] == true,
                              ),
                              child: Text(
                                '${a['label'] ?? a['id'] ?? ''}',
                                style: const TextStyle(color: Colors.white),
                              ),
                            ),
                      ],
                    );
                  },
                );
              },
            ),
          );
        },
      );
    } finally {
      _timeout?.cancel();
      for (final c in values.values) {
        c.dispose();
      }
      values.clear();
      _dialogOpen = false;
      _programmaticClose = false;
      if (_activeId != null && _doc.value == null) {
        _activeId = null;
      }
      if (!done.isCompleted) done.complete();
      if (_dialogDone == done) _dialogDone = null;
      // 若关闭过程中又来了新文档，重新打开。
      final pending = _doc.value;
      if (pending != null && !_dialogOpen) {
        final nextCtx = navigatorKey.currentContext;
        if (nextCtx != null) {
          _dialogOpen = true;
          final nextDone = Completer<void>();
          _dialogDone = nextDone;
          unawaited(_openDialog(nextCtx, nextDone));
        }
      }
    }
  }

  List<Widget> _buildElement(
    Map<String, dynamic> el, {
    required Map<String, TextEditingController> values,
    required Map<String, bool> checks,
    required Map<String, String> radios,
    required Map<String, String> selects,
    required void Function(VoidCallback) setLocal,
    required Future<void> Function(String action, {bool dismissAfter}) fire,
  }) {
    final type = '${el['type'] ?? ''}'.toLowerCase().trim();
    switch (type) {
      case 'text':
        return [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('${el['text'] ?? ''}', style: const TextStyle(color: Colors.white70, height: 1.35)),
          ),
        ];
      case 'image':
        final img = _decodeDataImage('${el['source'] ?? ''}');
        final w = (el['width'] is num) ? (el['width'] as num).toDouble() : 260.0;
        final h = (el['height'] is num) ? (el['height'] as num).toDouble() : 260.0;
        if (img == null) return const [];
        return [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Center(
              child: Image.memory(img, width: w, height: h, fit: BoxFit.contain),
            ),
          ),
        ];
      case 'progress':
        return [
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(child: CircularProgressIndicator(color: Color(0xFFE53955))),
          ),
        ];
      case 'input':
        final id = '${el['id'] ?? ''}';
        if (id.isEmpty) return const [];
        final ctrl = values.putIfAbsent(id, () {
          final c = TextEditingController(text: '${el['value'] ?? ''}');
          return c;
        });
        return [
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: TextField(
              controller: ctrl,
              obscureText: el['password'] == true,
              maxLines: el['multiline'] == true ? 3 : 1,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: '${el['placeholder'] ?? ''}',
                hintStyle: TextStyle(color: Colors.white.withOpacity(0.35)),
                enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white.withOpacity(0.2))),
                focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE53955))),
              ),
            ),
          ),
        ];
      case 'checkbox':
        final id = '${el['id'] ?? ''}';
        if (id.isEmpty) return const [];
        checks.putIfAbsent(id, () => el['checked'] == true);
        return [
          CheckboxListTile(
            value: checks[id] ?? false,
            title: Text('${el['text'] ?? ''}', style: const TextStyle(color: Colors.white70)),
            onChanged: (v) => setLocal(() => checks[id] = v ?? false),
            controlAffinity: ListTileControlAffinity.leading,
            activeColor: const Color(0xFFE53955),
          ),
        ];
      case 'radio':
        final id = '${el['id'] ?? ''}';
        if (id.isEmpty) return const [];
        final options = (el['options'] as List?) ?? const [];
        radios.putIfAbsent(id, () => '${el['value'] ?? ''}');
        return [
          for (final o in options)
            if (o is Map)
              RadioListTile<String>(
                value: '${o['id'] ?? ''}',
                groupValue: radios[id],
                title: Text('${o['label'] ?? o['id'] ?? ''}', style: const TextStyle(color: Colors.white70)),
                onChanged: (v) => setLocal(() => radios[id] = v ?? ''),
                activeColor: const Color(0xFFE53955),
              ),
        ];
      case 'select':
        final id = '${el['id'] ?? ''}';
        if (id.isEmpty) return const [];
        final options = (el['options'] as List?) ?? const [];
        selects.putIfAbsent(id, () => '${el['value'] ?? (options.isNotEmpty && options.first is Map ? options.first['id'] : '')}');
        return [
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: DropdownButtonFormField<String>(
              value: selects[id]?.isEmpty == true ? null : selects[id],
              dropdownColor: const Color(0xFF1A1028),
              style: const TextStyle(color: Colors.white),
              items: [
                for (final o in options)
                  if (o is Map)
                    DropdownMenuItem(value: '${o['id']}', child: Text('${o['label'] ?? o['id']}')),
              ],
              onChanged: (v) => setLocal(() => selects[id] = v ?? ''),
            ),
          ),
        ];
      case 'button':
        final btnUrl = '${el['url'] ?? ''}'.trim();
        return [
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () async {
                if (btnUrl.isNotEmpty) await _openExternal(btnUrl);
                await fire('${el['id'] ?? 'button'}', dismissAfter: el['dismiss'] == true);
              },
              child: Text('${el['text'] ?? ''}', style: const TextStyle(color: Colors.white)),
            ),
          ),
        ];
      case 'link':
        final linkUrl = '${el['url'] ?? ''}'.trim();
        if (linkUrl.isEmpty) return const [];
        final label = '${el['text'] ?? ''}'.trim().isEmpty ? linkUrl : '${el['text']}'.trim();
        final asButton = '${el['style'] ?? ''}'.toLowerCase().trim() == 'button';
        if (asButton) {
          return [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: const Color(0xFFE53955)),
                  onPressed: () => unawaited(_openExternal(linkUrl)),
                  child: Text(label),
                ),
              ),
            ),
          ];
        }
        return [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => unawaited(_openExternal(linkUrl)),
                child: Text(
                  label,
                  style: const TextStyle(color: Color(0xFF7EB8FF), decoration: TextDecoration.underline),
                ),
              ),
            ),
          ),
        ];
      case 'separator':
        return [Divider(color: Colors.white.withOpacity(0.15))];
      case 'spacer':
        final h = (el['height'] is num) ? (el['height'] as num).toDouble() : 8.0;
        return [SizedBox(height: h)];
      case 'space':
        return [const SizedBox(height: 12)];
      case 'row':
      case 'column':
      case 'group':
        final children = (el['children'] as List?) ?? const [];
        final kids = <Widget>[
          if (type == 'group' && '${el['text'] ?? ''}'.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text('${el['text']}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
            ),
          for (final c in children)
            if (c is Map)
              ..._buildElement(
                Map<String, dynamic>.from(c),
                values: values,
                checks: checks,
                radios: radios,
                selects: selects,
                setLocal: setLocal,
                fire: fire,
              ),
        ];
        if (type == 'row') {
          return [
            Wrap(spacing: 8, runSpacing: 8, children: kids),
          ];
        }
        return kids;
      default:
        return const [];
    }
  }

  /// 宿主只打开 URL / app scheme；具体深链由文档提供。
  Future<void> _openExternal(String raw) async {
    final s = raw.trim();
    if (s.isEmpty) return;
    final uri = Uri.tryParse(s);
    if (uri == null || !uri.hasScheme) return;
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (ok) return;
    } catch (_) {}
    try {
      if (Platform.isMacOS) {
        await Process.run('open', [s]);
      } else if (Platform.isWindows) {
        await Process.run('cmd', ['/c', 'start', '', s], runInShell: true);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [s]);
      }
    } catch (_) {}
  }

  Uint8List? _decodeDataImage(String source) {
    final src = source.trim();
    final comma = src.indexOf(',');
    if (!src.startsWith('data:') || comma < 0) return null;
    final meta = src.substring(0, comma);
    final payload = src.substring(comma + 1);
    try {
      if (meta.contains(';base64')) {
        return base64Decode(payload);
      }
      return Uint8List.fromList(utf8.encode(Uri.decodeComponent(payload)));
    } catch (_) {
      return null;
    }
  }
}
