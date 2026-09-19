import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'danmaku_file_read.dart';

/// 单条弹幕（internal/danmaku.Item）。
class DanmakuItem {
  const DanmakuItem({
    required this.time,
    required this.content,
    this.mode = 1,
    this.size = 25,
    this.color = 0xFFFFFF,
  });

  final double time; // 秒
  final String content;
  final int mode;
  final int size;
  final int color;
}

class DanmakuParser {
  static List<DanmakuItem> parse(String body) {
    final t = body.trim();
    if (t.contains('<d ') || t.contains('<i>')) {
      return _parseXml(t);
    }
    return _parseText(t);
  }

  static List<DanmakuItem> _parseXml(String body) {
    final out = <DanmakuItem>[];
    final re = RegExp(r'''<d\s+p="([^"]*)"[^>]*>([^<]*)</d>''', multiLine: true);
    for (final m in re.allMatches(body)) {
      final meta = m.group(1) ?? '';
      final text = _xmlUnescape(m.group(2) ?? '').trim();
      if (text.isEmpty) continue;
      final parts = meta.split(',');
      out.add(DanmakuItem(
        time: parts.isNotEmpty ? double.tryParse(parts[0]) ?? 0 : 0,
        mode: parts.length > 1 ? int.tryParse(parts[1]) ?? 1 : 1,
        size: parts.length > 2 ? int.tryParse(parts[2]) ?? 25 : 25,
        color: parts.length > 3 ? int.tryParse(parts[3]) ?? 0xFFFFFF : 0xFFFFFF,
        content: text,
      ));
    }
    return out;
  }

  static List<DanmakuItem> _parseText(String body) {
    final out = <DanmakuItem>[];
    final re = RegExp(r'^\[([^\]]+)\](.*)$');
    for (final line in body.split('\n')) {
      final m = re.firstMatch(line.trim());
      if (m == null) continue;
      final text = (m.group(2) ?? '').trim();
      if (text.isEmpty) continue;
      final parts = (m.group(1) ?? '').split(',');
      out.add(DanmakuItem(
        time: parts.isNotEmpty ? double.tryParse(parts[0]) ?? 0 : 0,
        mode: parts.length > 1 ? int.tryParse(parts[1]) ?? 1 : 1,
        size: parts.length > 2 ? int.tryParse(parts[2]) ?? 25 : 25,
        color: parts.length > 3 ? int.tryParse(parts[3]) ?? 0xFFFFFF : 0xFFFFFF,
        content: text,
      ));
    }
    return out;
  }

  static String _xmlUnescape(String s) => s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'");
}

class DanmakuLoader {
  static Future<List<DanmakuItem>> loadUrl(String url, {bool followSources = true}) async {
    if (url.trim().isEmpty) return const [];
    final resp = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 12));
    if (resp.statusCode < 200 || resp.statusCode >= 300) return const [];
    final body = utf8.decode(resp.bodyBytes, allowMalformed: true);
    return _parseBodyOrSources(body, followSources: followSources);
  }

  static Future<List<DanmakuItem>> loadFile(String path) async {
    final body = await readDanmakuFileText(path);
    if (body == null || body.isEmpty) return const [];
    return DanmakuParser.parse(body);
  }

  /// 模板 GET：`https://…?n={name}&e={episode}`；无占位符时 POST name/episode。
  /// 响应可为弹幕正文，或 `[{name,url},…]` 源列表（再拉首条 url）。
  static Future<List<DanmakuItem>> loadApi(String api, {required String name, required String episode}) async {
    final base = api.trim();
    if (base.isEmpty) return const [];
    final hasTpl = base.contains('{name}') || base.contains('{episode}');
    late final http.Response resp;
    if (hasTpl) {
      final u = base
          .replaceAll('{name}', Uri.encodeComponent(name))
          .replaceAll('{episode}', Uri.encodeComponent(episode));
      resp = await http.get(Uri.parse(u)).timeout(const Duration(seconds: 12));
    } else {
      resp = await http
          .post(
            Uri.parse(base),
            headers: {'Content-Type': 'application/x-www-form-urlencoded'},
            body: {'name': name, 'episode': episode},
          )
          .timeout(const Duration(seconds: 12));
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) return const [];
    final body = utf8.decode(resp.bodyBytes, allowMalformed: true);
    return _parseBodyOrSources(body, followSources: true);
  }

  static Future<List<DanmakuItem>> _parseBodyOrSources(String body, {required bool followSources}) async {
    if (followSources) {
      final src = _firstSourceUrl(body);
      if (src != null && src.isNotEmpty) {
        return loadUrl(src, followSources: false);
      }
    }
    return DanmakuParser.parse(body);
  }

  /// 弹幕搜索 API 常见返回：`[{"name":"…","url":"https://…xml"},…]`
  static String? _firstSourceUrl(String body) {
    final t = body.trim();
    if (t.isEmpty || (t[0] != '[' && t[0] != '{')) return null;
    try {
      final decoded = jsonDecode(t);
      if (decoded is List) {
        for (final item in decoded) {
          final u = _urlFromSource(item);
          if (u != null) return u;
        }
        return null;
      }
      return _urlFromSource(decoded);
    } catch (_) {
      return null;
    }
  }

  static String? _urlFromSource(dynamic item) {
    if (item is String) {
      final s = item.trim();
      return s.startsWith('http') ? s : null;
    }
    if (item is Map) {
      final u = '${item['url'] ?? ''}'.trim();
      if (u.startsWith('http')) return u;
    }
    return null;
  }
}

/// 全屏弹幕层：按播放进度滚动显示。
class DanmakuOverlay extends StatefulWidget {
  const DanmakuOverlay({
    super.key,
    required this.enabled,
    required this.position,
    required this.items,
    this.fontSize = 18,
    this.opacity = 0.85,
    this.rows = 6,
    this.maxOnScreen = 150,
    this.scrollAreaRatio = 0.5,
    this.showScroll = true,
    this.showTop = true,
    this.showBottom = true,
    this.showReverse = true,
    this.showSpecial = true,
    this.showPositioned = true,
    this.bold = false,
    this.durationMs = 8000,
    this.fixedDurationMs = 5000,
    this.lineSpacing = 1.4,
    this.strokeMode = 'shadow',
    this.colorMode = 'original',
    this.rowsTop = 3,
    this.rowsBottom = 3,
  });

  final bool enabled;
  final Duration position;
  final List<DanmakuItem> items;
  final double fontSize;
  final double opacity;
  final int rows;
  final int maxOnScreen;
  /// 滚动弹幕占用的画面高度比例（顶部起算）。
  final double scrollAreaRatio;
  final bool showScroll;
  final bool showTop;
  final bool showBottom;
  final bool showReverse;
  final bool showSpecial;
  final bool showPositioned;
  final bool bold;
  final int durationMs;
  final int fixedDurationMs;
  final double lineSpacing;
  final String strokeMode;
  final String colorMode;
  final int rowsTop;
  final int rowsBottom;

  @override
  State<DanmakuOverlay> createState() => _DanmakuOverlayState();
}

class _DanmakuOverlayState extends State<DanmakuOverlay> with SingleTickerProviderStateMixin {
  late final AnimationController _tick =
      AnimationController(vsync: this, duration: const Duration(days: 1))..repeat();
  final List<_Flying> _flying = [];
  double _lastSec = -1;

  @override
  void dispose() {
    _tick.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant DanmakuOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) {
      _flying.clear();
      _lastSec = -1;
      return;
    }
    if (!identical(oldWidget.items, widget.items) && oldWidget.items != widget.items) {
      _flying.clear();
      _lastSec = -1;
    }
  }

  bool _allowMode(int mode) {
    // bilibili / 常见 XML：1–3 滚动，4 底，5 顶，6 逆向，7 定位/高级，≥8 特殊。
    if (mode == 4) return widget.showBottom;
    if (mode == 5) return widget.showTop;
    if (mode == 6) return widget.showReverse;
    if (mode == 7) return widget.showPositioned;
    if (mode >= 8) return widget.showSpecial;
    return widget.showScroll;
  }

  void _spawn(Duration pos, Size size) {
    if (!widget.enabled || widget.items.isEmpty) return;
    final sec = pos.inMilliseconds / 1000.0;
    if (_lastSec < 0) _lastSec = sec;
    // 回退/跳播时重置窗口
    if (sec + 0.05 < _lastSec) {
      _flying.clear();
      _lastSec = sec;
    }
    final from = _lastSec;
    final to = sec + 0.35;
    final maxOn = widget.maxOnScreen.clamp(10, 500);
    final scrollDur = widget.durationMs.clamp(3000, 15000);
    final fixedDur = widget.fixedDurationMs.clamp(2000, 10000);
    for (final it in widget.items) {
      if (it.time >= from && it.time < to && _allowMode(it.mode)) {
        final lanes = widget.rows.clamp(1, 16);
        final fixed = it.mode == 4 || it.mode == 5 || it.mode == 7;
        _flying.add(_Flying(
          item: it,
          born: DateTime.now(),
          lane: math.Random(it.content.hashCode ^ sec.toInt()).nextInt(lanes),
          durationMs: fixed
              ? fixedDur
              : scrollDur + (it.content.length * 40).clamp(0, 3000),
        ));
      }
    }
    _lastSec = to;
    // 回收过期
    final now = DateTime.now();
    _flying.removeWhere((f) => now.difference(f.born).inMilliseconds > f.durationMs + 200);
    if (_flying.length > maxOn) {
      _flying.removeRange(0, _flying.length - maxOn);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return const SizedBox.shrink();
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _tick,
        builder: (context, _) {
          return LayoutBuilder(
            builder: (context, c) {
              _spawn(widget.position, Size(c.maxWidth, c.maxHeight));
              return CustomPaint(
                size: Size(c.maxWidth, c.maxHeight),
                painter: _DanmakuPainter(
                  flying: List.of(_flying),
                  now: DateTime.now(),
                  fontSize: widget.fontSize,
                  opacity: widget.opacity,
                  rows: widget.rows,
                  scrollAreaRatio: widget.scrollAreaRatio,
                  bold: widget.bold,
                  lineSpacing: widget.lineSpacing,
                  strokeMode: widget.strokeMode,
                  colorMode: widget.colorMode,
                  rowsTop: widget.rowsTop,
                  rowsBottom: widget.rowsBottom,
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _Flying {
  _Flying({
    required this.item,
    required this.born,
    required this.lane,
    required this.durationMs,
  });
  final DanmakuItem item;
  final DateTime born;
  final int lane;
  final int durationMs;
}

class _DanmakuPainter extends CustomPainter {
  _DanmakuPainter({
    required this.flying,
    required this.now,
    required this.fontSize,
    required this.opacity,
    required this.rows,
    this.scrollAreaRatio = 0.5,
    this.bold = false,
    this.lineSpacing = 1.4,
    this.strokeMode = 'shadow',
    this.colorMode = 'original',
    this.rowsTop = 3,
    this.rowsBottom = 3,
  });
  final List<_Flying> flying;
  final DateTime now;
  final double fontSize;
  final double opacity;
  final int rows;
  final double scrollAreaRatio;
  final bool bold;
  final double lineSpacing;
  final String strokeMode;
  final String colorMode;
  final int rowsTop;
  final int rowsBottom;

  Color _resolveColor(int raw) {
    final op = opacity.clamp(0.15, 1.0);
    switch (colorMode.trim().toLowerCase()) {
      case 'white':
        return Colors.white.withValues(alpha: op);
      case 'yellow':
        return const Color(0xFFFFFF00).withValues(alpha: op);
      default:
        return Color(0xFF000000 | (raw & 0xFFFFFF)).withValues(alpha: op);
    }
  }

  List<Shadow> _shadows() {
    switch (strokeMode.trim().toLowerCase()) {
      case 'none':
        return const [];
      case 'outline':
        return const [
          Shadow(offset: Offset(-1, 0), color: Colors.black87),
          Shadow(offset: Offset(1, 0), color: Colors.black87),
          Shadow(offset: Offset(0, -1), color: Colors.black87),
          Shadow(offset: Offset(0, 1), color: Colors.black87),
        ];
      default:
        return const [Shadow(blurRadius: 2, color: Colors.black87)];
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final lanes = rows.clamp(1, 16);
    final topLanes = rowsTop.clamp(1, 8);
    final bottomLanes = rowsBottom.clamp(1, 8);
    final areaH = (size.height * scrollAreaRatio.clamp(0.1, 1.0)).clamp(40.0, size.height);
    final laneH = (areaH / lanes * lineSpacing.clamp(1.0, 2.0)).clamp(20.0, 64.0);
    final shadows = _shadows();
    for (final f in flying) {
      final t = now.difference(f.born).inMilliseconds / f.durationMs;
      if (t < 0 || t > 1) continue;
      final fs = fontSize.clamp(12.0, 48.0);
      final tp = TextPainter(
        text: TextSpan(
          text: f.item.content,
          style: TextStyle(
            color: _resolveColor(f.item.color),
            fontSize: fs,
            fontWeight: bold ? FontWeight.w700 : FontWeight.w600,
            shadows: shadows,
          ),
        ),
        textDirection: ui.TextDirection.ltr,
        maxLines: 1,
      )..layout();
      final mode = f.item.mode;
      late final double x;
      late final double y;
      if (mode == 4) {
        x = (size.width - tp.width) / 2;
        y = size.height - 12.0 - tp.height - (f.lane % bottomLanes) * (tp.height + 4);
      } else if (mode == 5) {
        x = (size.width - tp.width) / 2;
        y = 12.0 + (f.lane % topLanes) * (tp.height + 4);
      } else if (mode == 7) {
        // 定位弹幕：按内容哈希落在画面中部附近。
        x = (size.width * 0.15) + (f.item.content.hashCode.abs() % 70) / 100.0 * size.width * 0.7 - tp.width / 2;
        y = (size.height * 0.2) + (f.lane % 5) / 5.0 * size.height * 0.5;
      } else if (mode == 6) {
        y = 12.0 + (f.lane % lanes) * laneH;
        x = -tp.width + t * (size.width + tp.width);
      } else if (mode >= 8) {
        // 特殊弹幕：居中短暂停留。
        x = (size.width - tp.width) / 2;
        y = size.height * 0.4 + (f.lane % 3) * (tp.height + 6);
      } else {
        y = 12.0 + (f.lane % lanes) * laneH;
        x = size.width - t * (size.width + tp.width);
      }
      tp.paint(canvas, Offset(x, y));
    }
  }

  @override
  bool shouldRepaint(covariant _DanmakuPainter old) => true;
}
