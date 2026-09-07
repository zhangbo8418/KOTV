import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import '../util/kotv_io.dart';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/kotv_api.dart';
import '../player/kotv_platform.dart';
import '../theme/kotv_palette.dart';
import '../theme/layout_scale.dart';
import '../widgets/chrome.dart';

/// 通用宿主弹窗：只认协议 [UI:] / [UI_CLOSE:]，不关心业务。
/// 脚本（JAR/JS/Py）决定内容与时机；宿主只负责：
/// - 展示 → 回报 `shown`（附带客户端 platform，供脚本按端生成 deep link）
/// - 关闭 → 回报 `closed`
///
/// platform 以 Flutter 前端为准（非引擎 OS）：iOS 连远程引擎时仍是 `ios`。
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

  /// 是否有声明式窗（含 opening 窗口期）；外壳返回键优先关窗。
  bool get hasOpenDialog => _sessionActive || _opening || _dialogContext != null;

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
  /// 用户/外壳取消时顺带 [cancelPending]，避免 JAR 占住后详情再也进不去。
  Future<void> cancelAll({bool reply = true, bool popDialog = true}) async {
    final id = _activeId ?? _lifecycleId;
    if (reply && id != null && id.isNotEmpty) {
      await _enqueueReply(id: id, action: 'dismiss', values: _hostClientValues());
    }
    _pendingDoc = null;
    unawaited(api.cancelPending(hard: false, thunder: false));
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
    _programmaticClose = true;
    NavigatorState? nav;
    final dialogCtx = _dialogContext;
    if (dialogCtx != null && dialogCtx.mounted) {
      try {
        nav = Navigator.of(dialogCtx, rootNavigator: true);
      } catch (_) {}
    }
    nav ??= navigatorKey.currentState;
    if (nav != null && nav.canPop()) {
      nav.pop();
      return;
    }
    // 弹不掉：会话与路由可能失步。清 context，并若已无 opening 则强制 idle，
    // 避免 hasOpenDialog 永久为 true 导致返回键只打空转、详情再也进不去。
    _dialogContext = null;
    if (!_opening && (_sessionActive || _lifecycleId != null)) {
      final id = (_lifecycleId ?? '').trim();
      if (id.isNotEmpty && !_reportedClosed) {
        _reportedClosed = true;
        unawaited(_enqueueReply(id: id, action: 'closed'));
      }
      _resetIdleState();
    }
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

  /// 客户端宿主信息（不是引擎机器）：脚本用 platform 决定 deep link / 按钮。
  Map<String, String> _hostClientValues([Map<String, String>? extra]) {
    final out = <String, String>{
      'platform': kotvHostPlatform(),
      'desktop': kotvIsDesktop() ? 'true' : 'false',
    };
    if (extra != null && extra.isNotEmpty) out.addAll(extra);
    return out;
  }

  Future<void> _reportShown(String id) async {
    if (_reportedShown || id.isEmpty) return;
    _reportedShown = true;
    await _enqueueReply(id: id, action: 'shown', values: _hostClientValues());
  }

  Future<void> _reportClosed() async {
    if (_reportedClosed) return;
    final id = (_lifecycleId ?? '').trim();
    if (id.isEmpty) return;
    _reportedClosed = true;
    await _enqueueReply(id: id, action: 'closed', values: _hostClientValues());
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
                // 手势/遥控返回：只关窗 + 通知脚本 dismiss，并打断占住的爬虫请求。
                if (_lifecycleId != null) {
                  unawaited(_enqueueReply(id: _lifecycleId!, action: 'dismiss', values: _hostClientValues()));
                }
                unawaited(api.cancelPending(hard: false, thunder: false));
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

                    final p = KotvPalette.of(ctx);
                    final s = hostUiScale(ctx);
                    final title = '${doc['title'] ?? ''}';
                    final elements = (doc['elements'] as List?) ?? const [];
                    final actions = (doc['actions'] as List?) ?? const [];
                    final docFont = _num(doc['fontSize']);
                    final titleFont = _num(doc['titleSize']);
                    final actionFont = _num(doc['actionFontSize']);
                    final actionH = _num(doc['actionHeight']);
                    final actionMaps = [
                      for (final a in actions)
                        if (a is Map) Map<String, dynamic>.from(a),
                    ];
                    final resolvedTitleFont = (titleFont >= 20
                            ? titleFont
                            : (kotvIsDesktop() ? 22.0 : (titleFont > 0 ? titleFont : 20.0))) *
                        s;

                    return _hostUiCard(
                      context: ctx,
                      doc: doc,
                      title: title.isEmpty
                          ? null
                          : Text(
                              title,
                              style: TextStyle(
                                color: p.fg,
                                fontSize: resolvedTitleFont,
                                fontWeight: FontWeight.w700,
                                height: 1.2,
                              ),
                            ),
                      body: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final el in elements)
                              if (el is Map)
                                ..._buildElement(
                                  Map<String, dynamic>.from(el),
                                  palette: p,
                                  docFontSize: docFont,
                                  uiScale: s,
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
                      actions: actionMaps.isEmpty
                          ? null
                          : _hostActionRow(
                              context: ctx,
                              actions: actionMaps,
                              defaultFont: (actionFont > 0 ? actionFont : docFont) * s,
                              defaultH: (actionH > 0 ? actionH : 40) * s,
                              onPressed: (a) => fire(
                                '${a['id'] ?? 'action'}',
                                dismissAfter: a['dismiss'] == true,
                              ),
                            ),
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
    final ctx = navigatorKey.currentContext;
    if (ctx == null) return const SizedBox.shrink();
    final p = KotvPalette.of(ctx);
    final title = '${doc['title'] ?? ''}';
    return _hostUiCard(
      context: ctx,
      doc: doc,
      title: title.isEmpty
          ? null
          : Text(title, style: TextStyle(color: p.fg, fontSize: 22, fontWeight: FontWeight.w700)),
      body: Center(child: CircularProgressIndicator(color: p.primary)),
    );
  }

  /// 设计稿 960×540，整窗（含弹窗）按屏等比缩放。
  /// 桌面仍用 [LayoutScale]（1280×720）。
  static double hostUiScale(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    if (kotvIsAndroid()) {
      final byW = size.width / 960.0;
      final byH = size.height / 540.0;
      return math.min(byW, byH).clamp(0.75, 1.55);
    }
    return LayoutScale.layoutOf(context);
  }

  /// 换源大卡片：半透明 dialogBg + 18 圆角描边；尺寸随 [hostUiScale] 自动缩放。
  Widget _hostUiCard({
    required BuildContext context,
    required Map<String, dynamic> doc,
    required Widget body,
    Widget? title,
    Widget? actions,
  }) {
    final p = KotvPalette.of(context);
    final screen = MediaQuery.sizeOf(context);
    final desktop = kotvIsDesktop();
    final s = hostUiScale(context);
    final compact = screen.width < 640 * s || screen.shortestSide < 560 * s;
    final inset = EdgeInsets.symmetric(
      horizontal: (compact ? 10.0 : (desktop ? 64.0 : 48.0)) * s,
      vertical: (compact ? 12.0 : (desktop ? 48.0 : 40.0)) * s,
    );
    final maxW = screen.width * 0.95;
    final maxH = screen.height * 0.9;
    final rawW = _num(doc['width']);
    final rawH = _num(doc['height']);
    // 脚本给的 width/font 按设计稿 dp；未给时默认卡宽也按 s 缩放。
    var cardW = rawW > 0 ? rawW * s : (desktop ? 560.0 : 420.0) * s;
    if (desktop && cardW < 520 * s) cardW = 520 * s;
    cardW = cardW.clamp(280.0 * s, maxW);
    final padH = (compact ? 14.0 : 24.0) * s;
    final padVT = (compact ? 14.0 : 22.0) * s;
    final padVB = (compact ? 12.0 : 18.0) * s;
    final gapTitle = (compact ? 8.0 : 12.0) * s;
    final gapActions = (compact ? 12.0 : 16.0) * s;
    final radius = 18.0 * s;

    // 内容区：可滚动 + 最大高度封顶；短内容随内容收缩（不强制撑满）。
    final bodyMaxH = math.max(
      80.0,
      maxH - padVT - padVB - (title != null ? 48 * s + gapTitle : 0) - (actions != null ? 48 * s + gapActions : 0) - 8,
    );
    final content = rawH > 0
        ? SizedBox(
            width: cardW,
            height: (rawH * s).clamp(120.0 * s, bodyMaxH),
            child: body,
          )
        : ConstrainedBox(
            constraints: BoxConstraints(maxWidth: cardW, maxHeight: bodyMaxH),
            child: body,
          );

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: inset,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: cardW, maxHeight: maxH),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: p.dialogBg,
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: p.outline),
          ),
          child: Padding(
            padding: EdgeInsets.fromLTRB(padH, padVT, padH, padVB),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (title != null) ...[
                  title,
                  SizedBox(height: gapTitle),
                ],
                content,
                if (actions != null) ...[
                  SizedBox(height: gapActions),
                  actions,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _hostActionRow({
    required BuildContext context,
    required List<Map<String, dynamic>> actions,
    required double defaultFont,
    required double defaultH,
    required void Function(Map<String, dynamic> action) onPressed,
  }) {
    final s = hostUiScale(context);
    final compact = MediaQuery.sizeOf(context).width < 640 * s;
    final gap = (compact ? 8.0 : 10.0) * s;
    return Row(
      children: [
        for (var i = 0; i < actions.length; i++) ...[
          if (i > 0) SizedBox(width: gap),
          Expanded(
            child: _hostActionPill(
              actions[i],
              compact: compact,
              selected: _isPrimaryAction(actions[i], actions.length),
              defaultFont: defaultFont,
              defaultH: defaultH,
              uiScale: s,
              onPressed: () => onPressed(actions[i]),
            ),
          ),
        ],
      ],
    );
  }

  bool _isPrimaryAction(Map<String, dynamic> a, int count) {
    final id = '${a['id'] ?? ''}'.toLowerCase().trim();
    if (id == 'submit' || id == 'ok' || id == 'confirm' || id == 'positive') return true;
    if (id == 'cancel' || id == 'close' || id == 'dismiss' || id == 'negative') return false;
    return count == 1;
  }

  Widget _hostActionPill(
    Map<String, dynamic> a, {
    required bool compact,
    required bool selected,
    required double defaultFont,
    required double defaultH,
    required double uiScale,
    required VoidCallback onPressed,
  }) {
    return LayoutBuilder(
      builder: (context, cons) {
        final ls = LayoutScale.layoutOf(context);
        final inv = ls > 0 ? 1.0 / ls : 1.0;
        // defaultFont/H 已含 uiScale；去掉 LayoutScale 再交给 AppPill，避免双重放大。
        final designFont = (_num(a['fontSize']) > 0
                ? _num(a['fontSize']) * uiScale
                : (defaultFont > 0 ? defaultFont : (compact ? 13.0 : 15.0) * uiScale)) *
            inv;
        final designH = (_num(a['height']) > 0
                ? _num(a['height']) * uiScale
                : (defaultH > 0 ? defaultH : (compact ? 36.0 : 40.0) * uiScale)) *
            inv;
        final w = cons.maxWidth.isFinite && cons.maxWidth > 0 ? cons.maxWidth / ls : 88.0;
        return AppPill(
          label: '${a['label'] ?? a['id'] ?? ''}',
          onTap: onPressed,
          selected: selected,
          width: w,
          height: designH,
          fontSize: designFont,
        );
      },
    );
  }

  double _num(dynamic v) => (v is num) ? v.toDouble() : 0.0;

  double _fontOf(Map<String, dynamic> el, double docFont) {
    final own = _num(el['fontSize']);
    if (own > 0) return own;
    if (docFont > 0) return docFont;
    return 14.0;
  }

  Widget _sized(Map<String, dynamic> el, {required Widget child, double uiScale = 1, double fallbackW = 0, double fallbackH = 0}) {
    final double? w = _num(el['width']) > 0
        ? _num(el['width']) * uiScale
        : (fallbackW > 0 ? fallbackW * uiScale : null);
    final double? h = _num(el['height']) > 0
        ? _num(el['height']) * uiScale
        : (fallbackH > 0 ? fallbackH * uiScale : null);
    if (w == null && h == null) return child;
    return SizedBox(width: w, height: h, child: child);
  }

  List<Widget> _buildElement(
    Map<String, dynamic> el, {
    required KotvPalette palette,
    required double docFontSize,
    required double uiScale,
    required Map<String, TextEditingController> values,
    required Map<String, bool> checks,
    required Map<String, String> radios,
    required Map<String, String> selects,
    required void Function(VoidCallback) setLocal,
    required Future<void> Function(String action, {bool dismissAfter}) fire,
  }) {
    final type = '${el['type'] ?? ''}'.toLowerCase().trim();
    final font = _fontOf(el, docFontSize) * uiScale;
    final pad = 8.0 * uiScale;
    switch (type) {
      case 'text':
        return [
          Padding(
            padding: EdgeInsets.only(bottom: pad),
            child: Text(
              '${el['text'] ?? ''}',
              style: TextStyle(color: palette.muted, height: 1.35, fontSize: font),
            ),
          ),
        ];
      case 'image':
        final img = _decodeDataImage('${el['source'] ?? ''}');
        if (img == null) return const [];
        final w = _num(el['width']) > 0 ? _num(el['width']) * uiScale : null;
        final h = _num(el['height']) > 0 ? _num(el['height']) * uiScale : null;
        return [
          Padding(
            padding: EdgeInsets.symmetric(vertical: pad),
            child: Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12 * uiScale),
                ),
                child: Padding(
                  padding: EdgeInsets.all(pad),
                  child: Image.memory(img, width: w, height: h, fit: BoxFit.contain),
                ),
              ),
            ),
          ),
        ];
      case 'progress':
        return [
          Padding(
            padding: EdgeInsets.symmetric(vertical: 12 * uiScale),
            child: Center(child: CircularProgressIndicator(color: palette.primary)),
          ),
        ];
      case 'input':
        final id = '${el['id'] ?? ''}';
        if (id.isEmpty) return const [];
        final ctrl = values.putIfAbsent(id, () {
          final c = TextEditingController(text: '${el['value'] ?? ''}');
          return c;
        });
        final field = TextField(
          controller: ctrl,
          obscureText: el['password'] == true,
          maxLines: el['multiline'] == true ? null : 1,
          minLines: el['multiline'] == true ? 3 : 1,
          style: TextStyle(color: palette.fg, fontSize: font),
          cursorColor: palette.primary,
          decoration: InputDecoration(
            hintText: '${el['placeholder'] ?? ''}',
            hintStyle: TextStyle(color: palette.muted, fontSize: font),
            filled: true,
            fillColor: palette.input,
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10 * uiScale),
              borderSide: BorderSide(color: palette.outline.withOpacity(0.45)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10 * uiScale),
              borderSide: BorderSide(color: palette.primary),
            ),
            isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 12 * uiScale, vertical: 10 * uiScale),
          ),
        );
        return [
          Padding(
            padding: EdgeInsets.only(bottom: 10 * uiScale),
            child: _sized(el, uiScale: uiScale, child: field),
          ),
        ];
      case 'checkbox':
        final id = '${el['id'] ?? ''}';
        if (id.isEmpty) return const [];
        checks.putIfAbsent(id, () => el['checked'] == true);
        return [
          CheckboxListTile(
            value: checks[id] ?? false,
            title: Text('${el['text'] ?? ''}', style: TextStyle(color: palette.muted, fontSize: font)),
            onChanged: (v) => setLocal(() => checks[id] = v ?? false),
            controlAffinity: ListTileControlAffinity.leading,
            activeColor: palette.primary,
            dense: true,
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
                title: Text('${o['label'] ?? o['id'] ?? ''}', style: TextStyle(color: palette.muted, fontSize: font)),
                onChanged: (v) => setLocal(() => radios[id] = v ?? ''),
                activeColor: palette.primary,
                dense: true,
              ),
        ];
      case 'select':
        final id = '${el['id'] ?? ''}';
        if (id.isEmpty) return const [];
        final options = (el['options'] as List?) ?? const [];
        selects.putIfAbsent(id, () => '${el['value'] ?? (options.isNotEmpty && options.first is Map ? options.first['id'] : '')}');
        final dropdown = DropdownButtonFormField<String>(
          value: selects[id]?.isEmpty == true ? null : selects[id],
          dropdownColor: palette.dialogBg,
          style: TextStyle(color: palette.fg, fontSize: font),
          items: [
            for (final o in options)
              if (o is Map)
                DropdownMenuItem(value: '${o['id']}', child: Text('${o['label'] ?? o['id']}', style: TextStyle(fontSize: font))),
          ],
          onChanged: (v) => setLocal(() => selects[id] = v ?? ''),
        );
        return [
          Padding(
            padding: EdgeInsets.only(bottom: 10 * uiScale),
            child: _sized(el, uiScale: uiScale, child: dropdown),
          ),
        ];
      case 'button':
        final btnUrl = '${el['url'] ?? ''}'.trim();
        return [
          Padding(
            padding: EdgeInsets.only(bottom: pad),
            child: Builder(
              builder: (context) {
                final ls = LayoutScale.layoutOf(context);
                final inv = ls > 0 ? 1.0 / ls : 1.0;
                return AppPill(
                  label: '${el['text'] ?? ''}',
                  fontSize: font * inv,
                  height: (_num(el['height']) > 0 ? _num(el['height']) * uiScale : 40 * uiScale) * inv,
                  width: _num(el['width']) > 0 ? _num(el['width']) * uiScale * inv : null,
                  onTap: () async {
                    if (btnUrl.isNotEmpty) await _openExternal(btnUrl);
                    await fire('${el['id'] ?? 'button'}', dismissAfter: el['dismiss'] == true);
                  },
                );
              },
            ),
          ),
        ];
      case 'link':
        final linkUrl = '${el['url'] ?? ''}'.trim();
        if (linkUrl.isEmpty) return const [];
        final labelText = '${el['text'] ?? ''}'.trim().isEmpty ? linkUrl : '${el['text']}'.trim();
        final asButton = '${el['style'] ?? ''}'.toLowerCase().trim() == 'button';
        if (asButton) {
          return [
            Padding(
              padding: EdgeInsets.only(bottom: pad),
              child: Builder(
                builder: (context) {
                  final ls = LayoutScale.layoutOf(context);
                  final inv = ls > 0 ? 1.0 / ls : 1.0;
                  return AppPill(
                    label: labelText,
                    selected: true,
                    fontSize: font * inv,
                    height: (_num(el['height']) > 0 ? _num(el['height']) * uiScale : 40 * uiScale) * inv,
                    width: _num(el['width']) > 0 ? _num(el['width']) * uiScale * inv : null,
                    onTap: () => unawaited(_openExternal(linkUrl)),
                  );
                },
              ),
            ),
          ];
        }
        return [
          Padding(
            padding: EdgeInsets.only(bottom: 4 * uiScale),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => unawaited(_openExternal(linkUrl)),
                child: Text(
                  labelText,
                  style: TextStyle(color: palette.primary, decoration: TextDecoration.underline, fontSize: font),
                ),
              ),
            ),
          ),
        ];
      case 'separator':
        return [Divider(color: palette.outline.withOpacity(0.45))];
      case 'spacer':
      case 'space':
        final sp = _num(el['height']) * uiScale;
        if (sp <= 0) return const [];
        return [SizedBox(height: sp)];
      case 'row':
      case 'column':
      case 'group':
        final children = (el['children'] as List?) ?? const [];
        final spacing = (_num(el['spacing']) > 0 ? _num(el['spacing']) : 0.0) * uiScale;
        final kids = <Widget>[
          if (type == 'group' && '${el['text'] ?? ''}'.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(bottom: spacing),
              child: Text('${el['text']}', style: TextStyle(color: palette.fg, fontWeight: FontWeight.w600, fontSize: font)),
            ),
          for (final c in children)
            if (c is Map)
              ..._buildElement(
                Map<String, dynamic>.from(c),
                palette: palette,
                docFontSize: docFontSize,
                uiScale: uiScale,
                values: values,
                checks: checks,
                radios: radios,
                selects: selects,
                setLocal: setLocal,
                fire: fire,
              ),
        ];
        if (type == 'row') {
          return [Wrap(spacing: spacing, runSpacing: spacing, children: kids)];
        }
        if (type == 'column' && spacing > 0) {
          final spaced = <Widget>[];
          for (var i = 0; i < kids.length; i++) {
            if (i > 0) spaced.add(SizedBox(height: spacing));
            spaced.add(kids[i]);
          }
          return spaced;
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
        // 勿用 `cmd /c start URL`：查询串里的 & 会被 cmd 当成命令分隔符截断。
        await Process.run('rundll32', ['url.dll,FileProtocolHandler', s]);
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
