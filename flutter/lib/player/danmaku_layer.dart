import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

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
  static Future<List<DanmakuItem>> loadUrl(String url) async {
    if (url.trim().isEmpty) return const [];
    final resp = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 12));
    if (resp.statusCode < 200 || resp.statusCode >= 300) return const [];
    final body = utf8.decode(resp.bodyBytes, allowMalformed: true);
    return DanmakuParser.parse(body);
  }

  /// 模板如 `https://…?n={name}&e={episode}`
  static Future<List<DanmakuItem>> loadApi(String api, {required String name, required String episode}) async {
    if (api.trim().isEmpty) return const [];
    final u = api.replaceAll('{name}', Uri.encodeComponent(name)).replaceAll('{episode}', Uri.encodeComponent(episode));
    return loadUrl(u);
  }
}

/// 全屏弹幕层：按播放进度滚动显示。
class DanmakuOverlay extends StatefulWidget {
  const DanmakuOverlay({
    super.key,
    required this.enabled,
    required this.position,
    required this.items,
  });

  final bool enabled;
  final Duration position;
  final List<DanmakuItem> items;

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
    for (final it in widget.items) {
      if (it.time >= from && it.time < to) {
        _flying.add(_Flying(
          item: it,
          born: DateTime.now(),
          lane: math.Random(it.content.hashCode ^ sec.toInt()).nextInt(8),
          durationMs: 6500 + (it.content.length * 80).clamp(0, 4000),
        ));
      }
    }
    _lastSec = to;
    // 回收过期
    final now = DateTime.now();
    _flying.removeWhere((f) => now.difference(f.born).inMilliseconds > f.durationMs + 200);
    if (_flying.length > 80) {
      _flying.removeRange(0, _flying.length - 80);
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
                painter: _DanmakuPainter(flying: List.of(_flying), now: DateTime.now()),
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
  _DanmakuPainter({required this.flying, required this.now});
  final List<_Flying> flying;
  final DateTime now;

  @override
  void paint(Canvas canvas, Size size) {
    for (final f in flying) {
      final t = now.difference(f.born).inMilliseconds / f.durationMs;
      if (t < 0 || t > 1) continue;
      final tp = TextPainter(
        text: TextSpan(
          text: f.item.content,
          style: TextStyle(
            color: Color(0xFF000000 | (f.item.color & 0xFFFFFF)).withOpacity(0.92),
            fontSize: (f.item.size.clamp(16, 36)).toDouble(),
            fontWeight: FontWeight.w600,
            shadows: const [Shadow(blurRadius: 2, color: Colors.black87)],
          ),
        ),
        textDirection: ui.TextDirection.ltr,
        maxLines: 1,
      )..layout();
      final y = 12.0 + f.lane * (size.height * 0.08).clamp(22.0, 40.0);
      final x = size.width - t * (size.width + tp.width);
      tp.paint(canvas, Offset(x, y));
    }
  }

  @override
  bool shouldRepaint(covariant _DanmakuPainter oldDelegate) => true;
}
