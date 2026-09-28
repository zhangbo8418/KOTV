import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'danmaku_file_read.dart';
import 'kotv_playback.dart';

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
    final all = listSources(body);
    return all.isEmpty ? null : all.first.url;
  }

  static List<DanmakuSource> listSources(String body) {
    final t = body.trim();
    if (t.isEmpty || (t[0] != '[' && t[0] != '{')) return const [];
    try {
      final decoded = jsonDecode(t);
      final out = <DanmakuSource>[];
      if (decoded is List) {
        for (var i = 0; i < decoded.length; i++) {
          final s = _sourceFrom(decoded[i], i);
          if (s != null) out.add(s);
        }
        return out;
      }
      final one = _sourceFrom(decoded, 0);
      return one == null ? const [] : [one];
    } catch (_) {
      return const [];
    }
  }

  static DanmakuSource? _sourceFrom(dynamic item, int index) {
    if (item is String) {
      final s = item.trim();
      if (!s.startsWith('http')) return null;
      return DanmakuSource(name: '源 ${index + 1}', url: s);
    }
    if (item is Map) {
      final u = '${item['url'] ?? ''}'.trim();
      if (!u.startsWith('http')) return null;
      final n = '${item['name'] ?? item['title'] ?? ''}'.trim();
      return DanmakuSource(name: n.isEmpty ? '源 ${index + 1}' : n, url: u);
    }
    return null;
  }

  /// 拉搜索接口正文（不跟进源），便于列出多源。
  static Future<String> fetchApiBody(String api, {required String name, required String episode}) async {
    final base = api.trim();
    if (base.isEmpty) return '';
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
    if (resp.statusCode < 200 || resp.statusCode >= 300) return '';
    return utf8.decode(resp.bodyBytes, allowMalformed: true);
  }

  static String? _urlFromSource(dynamic item) {
    return _sourceFrom(item, 0)?.url;
  }
}

class DanmakuSource {
  const DanmakuSource({required this.name, required this.url});
  final String name;
  final String url;
}

/// 叠在画面上的弹幕层：跟 [KotvPlayback.positionStream] 与媒体时钟滚动，
/// 不依赖父组件 setState；暂停时冻结，倍速跟播放速率。
class DanmakuOverlay extends StatefulWidget {
  const DanmakuOverlay({
    super.key,
    required this.enabled,
    required this.player,
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
    this.fontFamily = 'default',
  });

  final bool enabled;
  final KotvPlayback player;
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
  final String fontFamily;

  @override
  State<DanmakuOverlay> createState() => _DanmakuOverlayState();
}

class _DanmakuOverlayState extends State<DanmakuOverlay> with SingleTickerProviderStateMixin {
  static const _maxActivateWindowSec = 3.0;

  late final AnimationController _tick =
      AnimationController(vsync: this, duration: const Duration(days: 1));
  StreamSubscription<Duration>? _posSub;
  final List<_Flying> _flying = [];
  List<DanmakuItem> _sorted = const [];
  int _cursor = 0;
  double _lastActivateSec = -1;

  /// 媒体时钟：播中用墙钟外推，暂停钉住；positionStream 定期校准。
  Duration _basePos = Duration.zero;
  int _baseElapsedMs = 0;
  bool _paused = true;
  double _rate = 1.0;

  @override
  void initState() {
    super.initState();
    _sorted = _sortedCopy(widget.items);
    _bindPlayer(widget.player);
    _syncTicker();
  }

  @override
  void dispose() {
    _posSub?.cancel();
    widget.player.removeListener(_onPlayerNotify);
    _tick.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant DanmakuOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.player, widget.player)) {
      oldWidget.player.removeListener(_onPlayerNotify);
      _posSub?.cancel();
      _bindPlayer(widget.player);
    }
    if (!identical(oldWidget.items, widget.items) && oldWidget.items != widget.items) {
      _sorted = _sortedCopy(widget.items);
      _flying.clear();
      _cursor = 0;
      _lastActivateSec = -1;
    }
    if (oldWidget.enabled != widget.enabled) {
      if (!widget.enabled) {
        _flying.clear();
        _lastActivateSec = -1;
      } else {
        _rebase(widget.player.position, paused: !widget.player.playing, rate: widget.player.rate);
        _lastActivateSec = -1;
        _cursor = 0;
      }
    }
    _syncTicker();
  }

  List<DanmakuItem> _sortedCopy(List<DanmakuItem> items) {
    if (items.isEmpty) return const [];
    final out = List<DanmakuItem>.of(items);
    out.sort((a, b) => a.time.compareTo(b.time));
    return out;
  }

  void _bindPlayer(KotvPlayback p) {
    _rebase(p.position, paused: !p.playing, rate: p.rate);
    _posSub = p.positionStream.listen(_onPosition);
    p.addListener(_onPlayerNotify);
  }

  void _onPlayerNotify() {
    if (!mounted) return;
    final p = widget.player;
    final playing = p.playing;
    final rate = p.rate <= 0 ? 1.0 : p.rate;
    if (playing == !_paused && (rate - _rate).abs() < 0.001) return;
    // 暂停瞬间钉住外推位置，避免 MPV position 尚未刷新导致回跳。
    final pin = (!playing && !_paused) ? _mediaPos : p.position;
    _rebase(pin, paused: !playing, rate: rate);
    _syncTicker();
  }

  void _onPosition(Duration d) {
    if (!mounted) return;
    final jumpBack = d + const Duration(milliseconds: 400) < _mediaPos;
    final jumpFwd = d > _mediaPos + const Duration(seconds: 2);
    _rebase(d, paused: !widget.player.playing, rate: widget.player.rate);
    if (jumpBack || jumpFwd) {
      _flying.clear();
      _lastActivateSec = -1;
      _cursor = 0;
    }
  }

  void _rebase(Duration pos, {required bool paused, required double rate}) {
    _basePos = pos;
    _baseElapsedMs = DateTime.now().millisecondsSinceEpoch;
    _paused = paused;
    _rate = rate <= 0 ? 1.0 : rate;
  }

  Duration get _mediaPos {
    if (_paused) return _basePos;
    final elapsed = DateTime.now().millisecondsSinceEpoch - _baseElapsedMs;
    return _basePos + Duration(milliseconds: (elapsed * _rate).round());
  }

  void _syncTicker() {
    final want = widget.enabled && !_paused;
    if (want) {
      if (!_tick.isAnimating) _tick.repeat();
      return;
    }
    if (_tick.isAnimating) {
      _tick.stop();
      if (mounted) setState(() {});
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

  void _activate(double mediaSec, {required double viewW}) {
    if (!widget.enabled || _sorted.isEmpty) return;
    if (_lastActivateSec < 0) {
      _lastActivateSec = mediaSec;
      // 首次：游标移到当前时间，避免一上来把片头全吐出。
      while (_cursor < _sorted.length && _sorted[_cursor].time < mediaSec) {
        _cursor++;
      }
      return;
    }
    if (mediaSec + 0.05 < _lastActivateSec) {
      _flying.clear();
      _lastActivateSec = mediaSec;
      _cursor = 0;
      while (_cursor < _sorted.length && _sorted[_cursor].time < mediaSec) {
        _cursor++;
      }
      return;
    }
    final from = _lastActivateSec;
    final to = mediaSec;
    if (to <= from) return;
    final windowFrom = math.max(from, to - _maxActivateWindowSec);
    final maxOn = widget.maxOnScreen.clamp(10, 500);
    final scrollDur = widget.durationMs.clamp(3000, 15000);
    final fixedDur = widget.fixedDurationMs.clamp(2000, 10000);
    final lanes = widget.rows.clamp(1, 16);
    final topLanes = widget.rowsTop.clamp(1, 8);
    final bottomLanes = widget.rowsBottom.clamp(1, 8);
    final fs = widget.fontSize.clamp(12.0, 48.0);

    while (_cursor < _sorted.length && _sorted[_cursor].time < windowFrom) {
      _cursor++;
    }
    var i = _cursor;
    while (i < _sorted.length) {
      final it = _sorted[i];
      if (it.time >= to) break;
      if (it.time >= windowFrom && _allowMode(it.mode)) {
        if (_flying.length >= maxOn) break;
        final mode = it.mode;
        final fixed = mode == 4 || mode == 5 || mode == 7 || mode >= 8;
        final durationMs = fixed
            ? fixedDur
            : scrollDur + (it.content.length * 40).clamp(0, 3000);
        final textW = _estimateTextWidth(it.content, fs);
        final int? lane;
        if (mode == 4) {
          lane = _pickFixedLane(bottomLanes, top: false, mediaSec: mediaSec);
        } else if (mode == 5) {
          lane = _pickFixedLane(topLanes, top: true, mediaSec: mediaSec);
        } else if (mode == 7 || mode >= 8) {
          // 定位/特殊：占位不强占滚动轨，用内容哈希落点。
          lane = it.content.hashCode.abs() % 5;
        } else if (mode == 6) {
          lane = _pickScrollLane(
            lanes: lanes,
            mediaSec: mediaSec,
            viewW: viewW,
            textW: textW,
            durationMs: durationMs,
            reverse: true,
          );
        } else {
          lane = _pickScrollLane(
            lanes: lanes,
            mediaSec: mediaSec,
            viewW: viewW,
            textW: textW,
            durationMs: durationMs,
            reverse: false,
          );
        }
        if (lane != null) {
          _flying.add(_Flying(
            item: it,
            activatedSec: it.time,
            lane: lane,
            durationMs: durationMs,
            textWidth: textW,
          ));
        }
      }
      i++;
    }
    _cursor = i;
    _lastActivateSec = to;

    _flying.removeWhere(
      (f) => mediaSec - f.activatedSec > f.durationMs / 1000.0 + 0.25 || mediaSec < f.activatedSec - 0.05,
    );
    if (_flying.length > maxOn) {
      _flying.removeRange(0, _flying.length - maxOn);
    }
  }

  double _estimateTextWidth(String text, double fontSize) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w600),
      ),
      textDirection: ui.TextDirection.ltr,
      maxLines: 1,
    )..layout();
    return tp.width;
  }

  /// 滚动轨：无可用轨返回 null（丢弃，避免叠轨）。
  int? _pickScrollLane({
    required int lanes,
    required double mediaSec,
    required double viewW,
    required double textW,
    required int durationMs,
    required bool reverse,
  }) {
    if (viewW < 1) return 0;
    final gap = viewW * 0.08;
    for (var lane = 0; lane < lanes; lane++) {
      if (_scrollLaneFree(
        lane: lane,
        mediaSec: mediaSec,
        viewW: viewW,
        textW: textW,
        durationMs: durationMs,
        reverse: reverse,
        gap: gap,
      )) {
        return lane;
      }
    }
    return null;
  }

  bool _scrollLaneFree({
    required int lane,
    required double mediaSec,
    required double viewW,
    required double textW,
    required int durationMs,
    required bool reverse,
    required double gap,
  }) {
    final newDur = durationMs / 1000.0;
    if (newDur <= 0) return false;
    final newTravel = viewW + textW;
    final newSpeed = newTravel / newDur;
    for (final f in _flying) {
      final mode = f.item.mode;
      final fReverse = mode == 6;
      final fScroll = mode != 4 && mode != 5 && mode != 7 && mode < 8;
      if (mode != 6 && !fScroll) continue;
      if (fReverse != reverse) continue;
      if (f.lane != lane) continue;
      final durSec = f.durationMs / 1000.0;
      if (durSec <= 0) continue;
      final t = ((mediaSec - f.activatedSec) / durSec).clamp(0.0, 1.0);
      final existW = f.textWidth > 0 ? f.textWidth : _estimateTextWidth(f.item.content, widget.fontSize);
      final travel = viewW + existW;
      final x = reverse ? -existW + t * travel : viewW - t * travel;
      final right = x + existW;
      final oldSpeed = travel / durSec;
      if (!reverse) {
        // 新弹从右侧进入；尾弹右缘须已离开右缘足够间隙。
        if (right > viewW - gap) return false;
        if (newSpeed > oldSpeed + 0.5) {
          final headStart = viewW - right;
          if (headStart <= 0) return false;
          final catchTime = headStart / (newSpeed - oldSpeed);
          final remain = (1 - t) * durSec;
          if (catchTime < remain) return false;
        }
      } else {
        // 逆向从左侧进入；尾弹左缘须已离开左缘足够间隙。
        if (x < gap) return false;
        if (newSpeed > oldSpeed + 0.5) {
          final headStart = x;
          if (headStart <= 0) return false;
          final catchTime = headStart / (newSpeed - oldSpeed);
          final remain = (1 - t) * durSec;
          if (catchTime < remain) return false;
        }
      }
    }
    return true;
  }

  int? _pickFixedLane(int rows, {required bool top, required double mediaSec}) {
    final occupied = <int>{};
    for (final f in _flying) {
      final mode = f.item.mode;
      if (top && mode != 5) continue;
      if (!top && mode != 4) continue;
      final durSec = f.durationMs / 1000.0;
      if (mediaSec - f.activatedSec < durSec) {
        occupied.add(f.lane % rows);
      }
    }
    for (var i = 0; i < rows; i++) {
      if (!occupied.contains(i)) return i;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return const SizedBox.shrink();
    return IgnorePointer(
      child: ClipRect(
        child: AnimatedBuilder(
          animation: _tick,
          builder: (context, _) {
            return LayoutBuilder(
              builder: (context, c) {
                final w = c.maxWidth;
                final h = c.maxHeight;
                if (w < 1 || h < 1) return const SizedBox.shrink();
                final mediaSec = _mediaPos.inMilliseconds / 1000.0;
                if (!_paused) _activate(mediaSec, viewW: w);
                return CustomPaint(
                  size: Size(w, h),
                  painter: _DanmakuPainter(
                    flying: List.of(_flying),
                    mediaSec: mediaSec,
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
                    fontFamily: widget.fontFamily,
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _Flying {
  _Flying({
    required this.item,
    required this.activatedSec,
    required this.lane,
    required this.durationMs,
    this.textWidth = 0,
  });
  final DanmakuItem item;
  final double activatedSec;
  final int lane;
  final int durationMs;
  final double textWidth;
}

class _DanmakuPainter extends CustomPainter {
  _DanmakuPainter({
    required this.flying,
    required this.mediaSec,
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
    this.fontFamily = 'default',
  });
  final List<_Flying> flying;
  final double mediaSec;
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
  final String fontFamily;

  Color _resolveColor(int raw) {
    final op = opacity.clamp(0.15, 1.0);
    switch (colorMode.trim().toLowerCase()) {
      case 'white':
        return Colors.white.withOpacity(op);
      case 'yellow':
        return const Color(0xFFFFFF00).withOpacity(op);
      default:
        return Color(0xFF000000 | (raw & 0xFFFFFF)).withOpacity(op);
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
    final fs = fontSize.clamp(12.0, 48.0);
    // 行高不低于字高，避免邻轨纵向压字。
    final laneH = math.max(
      fs * lineSpacing.clamp(1.0, 2.0),
      areaH / lanes,
    ).clamp(fs, 80.0);
    final shadows = _shadows();
    for (final f in flying) {
      final durSec = f.durationMs / 1000.0;
      if (durSec <= 0) continue;
      final t = (mediaSec - f.activatedSec) / durSec;
      if (t < 0 || t > 1) continue;
      final fs = fontSize.clamp(12.0, 48.0);
      final family = switch (fontFamily.trim().toLowerCase()) {
        'sans' || 'sans-serif' => 'sans-serif',
        'serif' => 'serif',
        'mono' || 'monospace' => 'monospace',
        _ => null,
      };
      final tp = TextPainter(
        text: TextSpan(
          text: f.item.content,
          style: TextStyle(
            color: _resolveColor(f.item.color),
            fontSize: fs,
            fontFamily: family,
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
