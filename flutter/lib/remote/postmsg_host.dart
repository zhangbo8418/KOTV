import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/kotv_api.dart';

/// 通用宿主弹窗：只认协议 [UI:] / [UI_CLOSE:]，不关心业务。
/// 脚本（JAR/JS/Py）决定内容与时机；宿主只负责：
/// - 展示 → 回报 `shown`
/// - 关闭 → 回报 `closed`
///
/// 已有窗再来 [UI:]：同窗原地换文档（不 pop），并回报旧 id `closed` + 新 id `shown`。
/// 这是 Win7 关键：关开握手在慢机上会闪死/卡死，macOS 快所以不易踩中。
class PostMsgHost {
  PostMsgHost(this.api, {required this.navigatorKey});

  /// 当前活跃宿主（页面离开时可 cancelAll 关掉声明式窗并回传 dismiss）。
  static PostMsgHost? instance;

  final KotvApi api;
  final GlobalKey<NavigatorState> navigatorKey;

  Timer? _timer;
  Timer? _timeout;

  /// 已决定要开窗 / 正在展示（含 showDialog 尚未把路由挂上的窗口期）。
  bool _sessionActive = false;

  /// showDialog 的 Future 已发出、builder 尚未赋值 dialogContext。
  bool _opening = false;

  /// 在路由挂上前就收到了关闭请求。
  bool _closedBeforeShow = false;

  /// 是否由宿主主动 pop（区分用户返回键）。
  bool _programmaticClose = false;

  /// 本会话是否已回报过 shown / closed（避免重复）。
  bool _reportedShown = false;
  bool _reportedClosed = false;

  /// 仅用于 pop 本 dialog 路由。
  BuildContext? _dialogContext;

  String? _activeId;
  /// 曾成功挂上的会话 id（关窗后 _activeId 可能已清空，closed 仍用它）。
  String? _lifecycleId;
  final ValueNotifier<Map<String, dynamic>?> _doc = ValueNotifier(null);

  /// 关旧开新时暂存下一份文档（仅真正关窗后再开时使用）。
  Map<String, dynamic>? _pendingDoc;

  /// 生命周期 uiReply 单飞队列，保证同 id shown 先于 closed 入引擎。
  Future<void> _replyChain = Future<void>.value();

  /// 轮询单飞，避免 Win7 上 120ms tick 叠跑拧乱状态机。
  bool _tickBusy = false;

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

  /// 关掉当前声明式窗，并向引擎回传 dismiss。
  /// [popDialog] 保留兼容：关窗一律走 dialog context，不会误 pop 其它路由。
  Future<void> cancelAll({bool reply = true, bool popDialog = true}) async {
    final id = _activeId ?? _lifecycleId;
    if (reply && id != null && id.isNotEmpty) {
      await _enqueueReply(id: id, action: 'dismiss');
    }
    _pendingDoc = null;
    if (popDialog || _sessionActive || _opening) {
      _dismiss();
    } else {
      _activeId = null;
      _timeout?.cancel();
      _timeout = null;
    }
  }

  Future<void> _tick() async {
    if (_tickBusy) return;
    _tickBusy = true;
    try {
      final data = await api.uiPoll();
      final msgs = (data['messages'] as List?) ?? const [];
      // 同一批先 UI_CLOSE: 再 UI:：JAR 真正关窗时，先关干净再开。
      final ui = <String>[];
      final closes = <String>[];
      final other = <String>[];
      for (final raw in msgs) {
        final s = '${raw ?? ''}'.trim();
        if (s.startsWith('UI:')) {
          ui.add(s);
        } else if (s.startsWith('UI_CLOSE:')) {
          closes.add(s);
        } else if (s.isNotEmpty) {
          other.add(s);
        }
      }
      for (final s in closes) {
        _handle(s);
      }
      for (final s in ui) {
        _handle(s);
      }
      for (final s in other) {
        _handle(s);
      }
    } catch (_) {
    } finally {
      _tickBusy = false;
    }
  }

  void _handle(String raw) {
    final msg = raw.trim();
    if (msg.isEmpty) return;

    if (msg.startsWith('UI:')) {
      final payload = msg.substring(3);
      try {
        final decoded = jsonDecode(payload);
        if (decoded is Map && '${decoded['id'] ?? ''}'.isNotEmpty) {
          _show(Map<String, dynamic>.from(decoded));
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

  void _show(Map<String, dynamic> doc) {
    final id = '${doc['id']}'.trim();
    if (id.isEmpty) return;

    // 已有窗：原地换内容（不 pop）。Win7 关开握手会闪死；macOS 快所以以前不易暴露。
    if (_sessionActive || _opening) {
      final oldId = (_activeId ?? _lifecycleId ?? '').trim();
      _pendingDoc = null;
      _closedBeforeShow = false;
      _activeId = id;
      _lifecycleId = id;
      _reportedClosed = false;
      _reportedShown = false;
      _doc.value = doc;
      _armTimeout(doc);
      unawaited(_ackReplace(oldId: oldId, newId: id));
      return;
    }

    _pendingDoc = null;
    _activeId = id;
    _lifecycleId = id;
    _closedBeforeShow = false;
    _reportedShown = false;
    _reportedClosed = false;
    _armTimeout(doc);
    _doc.value = doc;

    final ctx = navigatorKey.currentContext;
    if (ctx == null) {
      unawaited(_enqueueReply(id: id, action: 'closed'));
      _resetIdleState();
      return;
    }

    _sessionActive = true;
    _opening = true;
    _programmaticClose = false;
    unawaited(_openDialog(ctx));
  }

  /// 同窗换文档：先给旧 session closed，再给新 session shown。
  Future<void> _ackReplace({required String oldId, required String newId}) async {
    if (oldId.isNotEmpty && oldId != newId) {
      await _enqueueReply(id: oldId, action: 'closed');
    }
    if (newId.isEmpty) return;
    if (_lifecycleId != newId || _reportedShown) return;
    await _reportShown(newId);
  }

  void _armTimeout(Map<String, dynamic> doc) {
    _timeout?.cancel();
    final timeoutMs = (doc['timeoutMs'] is num) ? (doc['timeoutMs'] as num).toInt() : 0;
    if (timeoutMs <= 0) return;
    final id = '${doc['id']}';
    _timeout = Timer(Duration(milliseconds: timeoutMs), () {
      if (_activeId != id) return;
      unawaited(_enqueueReply(id: id, action: 'timeout'));
      _dismiss();
    });
  }

  void _close(String id) {
    // 旧 session 的 CLOSE：只补 closed，不要关掉当前已换新文档的窗。
    if (_activeId != null && _activeId != id && _lifecycleId != id) {
      unawaited(_enqueueReply(id: id, action: 'closed'));
      return;
    }
    // 若 pending 是这份 id，清掉，避免关完又开回来。
    if (_pendingDoc != null && '${_pendingDoc!['id']}' == id) {
      _pendingDoc = null;
    }
    _dismiss();
  }

  void _dismiss() {
    _timeout?.cancel();
    _timeout = null;
    _activeId = null;
    // 不要立刻清空 _doc：保留最后一帧直到路由卸掉，避免空 barrier 闪烁。
    _closedBeforeShow = true;
    _popDialogRoute();
    // 若 showDialog 还没挂上就取消：直接回报 closed。
    if (!_sessionActive && !_opening) {
      unawaited(_reportClosed());
    } else if (_opening && _dialogContext == null) {
      // builder 尚未跑；等 finally / 早退路径回报。
    }
  }

  void _popDialogRoute() {
    final dialogCtx = _dialogContext;
    if (dialogCtx == null) return;
    if (!dialogCtx.mounted) {
      _dialogContext = null;
      return;
    }
    final nav = Navigator.of(dialogCtx, rootNavigator: false);
    if (!nav.canPop()) return;
    _programmaticClose = true;
    nav.pop();
  }

  Future<void> _enqueueReply({
    required String id,
    required String action,
    Map<String, String>? values,
  }) {
    final done = Completer<void>();
    _replyChain = _replyChain.catchError((_) {}).then((_) async {
      try {
        await api.uiReply(id: id, action: action, values: values);
      } catch (_) {
      } finally {
        if (!done.isCompleted) done.complete();
      }
    });
    return done.future;
  }

  Future<void> _reportShown(String id) async {
    if (_reportedShown || id.isEmpty) return;
    _reportedShown = true;
    await _enqueueReply(id: id, action: 'shown');
  }

  Future<void> _reportClosed() async {
    if (_reportedClosed) return;
    final id = (_lifecycleId ?? '').trim();
    if (id.isEmpty) return;
    _reportedClosed = true;
    await _enqueueReply(id: id, action: 'closed');
  }

  void _resetIdleState() {
    _timeout?.cancel();
    _timeout = null;
    _activeId = null;
    _lifecycleId = null;
    _doc.value = null;
    _pendingDoc = null;
    _sessionActive = false;
    _opening = false;
    _closedBeforeShow = false;
    _dialogContext = null;
    _programmaticClose = false;
    _reportedShown = false;
    _reportedClosed = false;
  }

  Future<void> _openDialog(BuildContext ctx) async {
    final values = <String, TextEditingController>{};
    final checks = <String, bool>{};
    final radios = <String, String>{};
    final selects = <String, String>{};
    var mountedRoute = false;

    try {
      if (_doc.value == null || _closedBeforeShow) {
        _sessionActive = false;
        _opening = false;
        await _reportClosed();
        return;
      }

      await showDialog<void>(
        context: ctx,
        useRootNavigator: true,
        barrierDismissible: false,
        builder: (dialogCtx) {
          _dialogContext = dialogCtx;
          _opening = false;
          mountedRoute = true;

          if (_closedBeforeShow) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _popDialogRoute();
              unawaited(_reportClosed());
            });
            // 仍渲染当前文档一帧，避免空 barrier 闪烁；随即 pop。
            final doc = _doc.value;
            if (doc == null) return const SizedBox.shrink();
            return _buildDialogShell(doc);
          }

          final shownId = _lifecycleId ?? _activeId ?? '';
          WidgetsBinding.instance.addPostFrameCallback((_) {
            // 用回调时的当前 id：opening 窗口期内可能已原地换成新 session。
            final id = (_lifecycleId ?? _activeId ?? '').trim();
            if (!_closedBeforeShow && _doc.value != null && id.isNotEmpty) {
              unawaited(_reportShown(id));
            }
          });

          return PopScope(
            canPop: true,
            onPopInvoked: (didPop) {
              if (!didPop) return;
              if (!_programmaticClose) {
                if (_lifecycleId != null) {
                  unawaited(_enqueueReply(id: _lifecycleId!, action: 'dismiss'));
                }
                _activeId = null;
              }
              _dialogContext = null;
            },
            child: ValueListenableBuilder<Map<String, dynamic>?>(
              valueListenable: _doc,
              builder: (ctx, doc, _) {
                if (doc == null) {
                  WidgetsBinding.instance.addPostFrameCallback((_) => _popDialogRoute());
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
                      await _enqueueReply(id: id, action: action, values: collect());
                      if (dismissAfter) {
                        _dismiss();
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
                );
              },
            ),
          );
        },
      );
    } finally {
      for (final c in values.values) {
        c.dispose();
      }
      values.clear();
      checks.clear();
      radios.clear();
      selects.clear();

      if (mountedRoute || _reportedShown || _lifecycleId != null) {
        await _reportClosed();
      }

      _dialogContext = null;
      _sessionActive = false;
      _opening = false;
      _closedBeforeShow = false;
      _programmaticClose = false;
      _timeout?.cancel();
      _timeout = null;
      _activeId = null;
      _doc.value = null;

      final pending = _pendingDoc;
      _pendingDoc = null;
      _lifecycleId = null;
      _reportedShown = false;
      _reportedClosed = false;

      if (pending != null) {
        // closed 已 await 入队后再开新窗。
        _show(pending);
      }
    }
  }

  /// 关窗瞬间仍展示最后一帧内容（无交互），避免空 barrier。
  Widget _buildDialogShell(Map<String, dynamic> doc) {
    final title = '${doc['title'] ?? ''}';
    final width = (doc['width'] is num) ? (doc['width'] as num).toDouble() : 420.0;
    final height = (doc['height'] is num) ? (doc['height'] as num).toDouble() : 480.0;
    return AlertDialog(
      backgroundColor: const Color(0xFF1A1028),
      title: title.isEmpty ? null : Text(title, style: const TextStyle(color: Colors.white)),
      content: SizedBox(
        width: width.clamp(200, 900),
        height: height.clamp(120, 900),
        child: const Center(
          child: CircularProgressIndicator(color: Colors.white54),
        ),
      ),
    );
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
