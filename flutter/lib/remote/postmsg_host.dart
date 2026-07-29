import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/kotv_api.dart';

/// 对齐 Legacy [listenSpiderPostMsg]：轮询引擎缓冲，只渲染声明式文档（内容/尺寸由 jar·js·py 决定）。
class PostMsgHost {
  PostMsgHost(this.api, {required this.navigatorKey});

  final KotvApi api;
  final GlobalKey<NavigatorState> navigatorKey;

  Timer? _timer;
  bool _busy = false;
  final List<Map<String, dynamic>> _queue = [];
  String? _activeId;
  VoidCallback? _activeDismiss;
  String _lastToast = '';
  DateTime _lastToastAt = DateTime.fromMillisecondsSinceEpoch(0);

  void start() {
    _timer?.cancel();
    unawaited(_tick());
    _timer = Timer.periodic(const Duration(milliseconds: 120), (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _activeDismiss?.call();
    _activeDismiss = null;
    _queue.clear();
    _busy = false;
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
          _enqueue(doc);
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

  void _enqueue(Map<String, dynamic> doc) {
    final id = '${doc['id']}';
    _queue.removeWhere((e) => '${e['id']}' == id);
    _queue.add(doc);
    final replaces = _activeId == id && _activeDismiss != null;
    final start = !_busy;
    if (start) _busy = true;
    if (replaces) _activeDismiss?.call();
    if (start) unawaited(_drain());
  }

  void _close(String id) {
    _queue.removeWhere((e) => '${e['id']}' == id);
    if (_activeId == id) {
      _activeDismiss?.call();
    }
  }

  Future<void> _drain() async {
    while (_queue.isNotEmpty) {
      final doc = _queue.removeAt(0);
      final id = '${doc['id']}';
      final done = Completer<void>();
      var programmatic = false;

      void finish() {
        if (!done.isCompleted) done.complete();
      }

      void dismiss() {
        programmatic = true;
        final nav = navigatorKey.currentState;
        if (nav != null && nav.canPop()) {
          nav.pop();
        }
        finish();
      }

      _activeId = id;
      _activeDismiss = dismiss;

      final ctx = navigatorKey.currentContext;
      if (ctx == null) {
        finish();
        continue;
      }

      final values = <String, TextEditingController>{};
      final checks = <String, bool>{};
      final radios = <String, String>{};
      final selects = <String, String>{};

      final timeoutMs = (doc['timeoutMs'] is num) ? (doc['timeoutMs'] as num).toInt() : 0;
      Timer? timeout;
      if (timeoutMs > 0) {
        timeout = Timer(Duration(milliseconds: timeoutMs), () {
          unawaited(api.uiReply(id: id, action: 'timeout'));
          dismiss();
        });
      }

      await showDialog<void>(
        context: ctx,
        barrierDismissible: true,
        builder: (dialogCtx) {
          return PopScope(
            onPopInvoked: (didPop) {
              if (!didPop) return;
              if (!programmatic) {
                unawaited(api.uiReply(id: id, action: 'dismiss'));
              }
              finish();
            },
            child: StatefulBuilder(
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
                  await api.uiReply(id: id, action: action, values: collect());
                  if (dismissAfter && ctx.mounted) {
                    programmatic = true;
                    Navigator.of(ctx).pop();
                    finish();
                  }
                }

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
            ),
          );
        },
      );

      timeout?.cancel();
      for (final c in values.values) {
        c.dispose();
      }
      if (_activeId == id) {
        _activeId = null;
        _activeDismiss = null;
      }
    }
    _busy = false;
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
