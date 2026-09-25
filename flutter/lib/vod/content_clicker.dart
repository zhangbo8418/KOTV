import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Sniffer.CLICKER：`[a=cr:{json}/]label[/a]`，json 为 Class（type_id / type_name）。
final RegExp kotvContentClicker = RegExp(
  r'\[a=cr:(\{.*?\})\/](.*?)\[\/a]',
  dotAll: true,
);

class KotvContentClick {
  const KotvContentClick({required this.typeId, required this.typeName, required this.label});
  final String typeId;
  final String typeName;
  final String label;
}

/// 从 CLICKER 标记解析目录入口；解析失败返回 null。
KotvContentClick? parseKotvContentClick(String jsonRaw, String label) {
  try {
    final m = jsonDecode(jsonRaw);
    if (m is! Map) return null;
    final typeId = '${m['type_id'] ?? m['id'] ?? ''}'.trim();
    final typeName = '${m['type_name'] ?? m['name'] ?? ''}'.trim();
    if (typeId.isEmpty) return null;
    final text = label.trim();
    return KotvContentClick(
      typeId: typeId,
      typeName: typeName.isNotEmpty ? typeName : text,
      label: text.isNotEmpty ? text : typeName,
    );
  } catch (_) {
    return null;
  }
}

/// 去掉 HTML 后保留 CLICKER。
String kotvStripHtmlKeepClicker(String raw) {
  return raw
      .replaceAll(RegExp(r'<[^>]*>'), ' ')
      .replaceAll(RegExp(r'[ \t]+'), ' ')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

/// 详情简介：解析 CLICKER 为可点链接；具体跳转由 [onOpen] 处理。
class KotvClickableContent extends StatefulWidget {
  const KotvClickableContent({
    super.key,
    required this.raw,
    required this.style,
    required this.linkStyle,
    required this.onOpen,
    this.prefix = '',
    this.maxLines,
  });

  final String raw;
  final TextStyle style;
  final TextStyle linkStyle;
  final void Function(KotvContentClick click) onOpen;
  final String prefix;
  final int? maxLines;

  @override
  State<KotvClickableContent> createState() => _KotvClickableContentState();
}

class _KotvClickableContentState extends State<KotvClickableContent> {
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
    super.dispose();
  }

  List<InlineSpan> _spans() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
    final text = kotvStripHtmlKeepClicker(widget.raw);
    final out = <InlineSpan>[];
    if (widget.prefix.isNotEmpty) {
      out.add(TextSpan(text: widget.prefix, style: widget.style));
    }
    if (text.isEmpty) {
      out.add(TextSpan(text: '暂无', style: widget.style));
      return out;
    }
    var last = 0;
    for (final m in kotvContentClicker.allMatches(text)) {
      if (m.start > last) {
        out.add(TextSpan(text: text.substring(last, m.start), style: widget.style));
      }
      final click = parseKotvContentClick(m.group(1) ?? '', m.group(2) ?? '');
      if (click == null) {
        out.add(TextSpan(text: m.group(0) ?? '', style: widget.style));
      } else {
        final recognizer = TapGestureRecognizer()..onTap = () => widget.onOpen(click);
        _recognizers.add(recognizer);
        out.add(TextSpan(text: click.label, style: widget.linkStyle, recognizer: recognizer));
      }
      last = m.end;
    }
    if (last < text.length) {
      out.add(TextSpan(text: text.substring(last), style: widget.style));
    }
    if (out.length == (widget.prefix.isEmpty ? 0 : 1)) {
      out.add(TextSpan(text: text, style: widget.style));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(children: _spans()),
      maxLines: widget.maxLines,
      overflow: widget.maxLines == null ? TextOverflow.clip : TextOverflow.ellipsis,
    );
  }
}
