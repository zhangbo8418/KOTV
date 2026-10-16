import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../providers.dart';
import '../theme/layout_scale.dart';
import '../theme/kotv_theme.dart';

/// 名称条上下左右内边距。
const double kotvPosterNamePad = 6;

/// 手机 14，电视 16。字号显式给出，再交给 [TextScaler]，测量和绘制用同一份样式。
double kotvPosterNameFont({required bool television}) => television ? 16 : 14;

TextStyle kotvPosterNameStyle({required bool television, Color? color}) {
  // 只有 Win7 指定 NotoSansSC。其它平台 fontFamily 留空，沿用系统字体。
  final family = kotvThemeFontFamily();
  return TextStyle(
    color: color,
    fontSize: kotvPosterNameFont(television: television),
    fontWeight: FontWeight.w700,
    height: 1.15,
    fontFamily: family,
    fontFamilyFallback: family == null ? null : kotvFontFallbacks(),
  );
}

final _posterNameLineHeights = <String, double>{};

double kotvPosterNameLineHeight({
  required bool television,
  TextScaler textScaler = TextScaler.noScaling,
}) {
  final style = kotvPosterNameStyle(television: television);
  final font = style.fontSize ?? kotvPosterNameFont(television: television);
  final key =
      '${style.fontFamily}|${style.fontWeight}|${style.height}|${textScaler.scale(font)}';
  final hit = _posterNameLineHeights[key];
  if (hit != null) return hit;
  final painter = TextPainter(
    text: TextSpan(text: '国', style: style),
    textDirection: TextDirection.ltr,
    textScaler: textScaler,
    maxLines: 1,
  )..layout();
  return _posterNameLineHeights[key] = painter.height;
}

/// 名称条盖在图片上，高度是一行字加上下内边距。
double kotvPosterTitleExtent({
  required bool television,
  TextScaler textScaler = TextScaler.noScaling,
}) {
  return kotvPosterNameLineHeight(
          television: television, textScaler: textScaler) +
      kotvPosterNamePad * 2;
}

class KotvGridStyle {
  const KotvGridStyle({this.type = 'rect', this.ratio = 0.75});

  final String type;
  final double ratio;

  bool get isList => type == 'list';
  bool get isOval => type == 'oval';
  bool get isLand => type == 'rect' && ratio > 1;

  static KotvGridStyle parse(dynamic v) {
    if (v is Map) {
      return normalize('${v['type'] ?? ''}', _num(v['ratio']));
    }
    if (v is String && v.trim().isNotEmpty) {
      return normalize(v, 0);
    }
    return const KotvGridStyle();
  }

  static KotvGridStyle normalize(String rawType, double rawRatio) {
    var t = rawType.trim().toLowerCase();
    if (t != 'list' && t != 'oval' && t != 'rect') t = 'rect';
    if (t == 'list') return const KotvGridStyle(type: 'list', ratio: 1);
    return KotvGridStyle(
        type: t, ratio: clampRatio(rawRatio, oval: t == 'oval'));
  }

  static double clampRatio(double ratio, {required bool oval}) {
    if (ratio <= 0) return oval ? 1 : 0.75;
    if (ratio > 4) return 4;
    return ratio;
  }

  static double _num(dynamic v) {
    if (v is num) return v.toDouble();
    return double.tryParse('$v') ?? 0;
  }
}

/// 海报尺寸档。空值默认 2（大）。范围 0..3。
int kotvPosterSizeValue(String? raw) {
  final n = int.tryParse((raw ?? '').trim());
  if (n == null) return 2;
  if (n < 0) return 0;
  if (n > 3) return 3;
  return n;
}

KotvGridStyle kotvGridStyleOfItems(List<VodItem> items) {
  if (items.isEmpty) return const KotvGridStyle();
  final it = items.first;
  if (it.styleType.trim().isEmpty) {
    return KotvGridStyle(ratio: it.styleRatio <= 0 ? 0.75 : it.styleRatio);
  }
  return KotvGridStyle.normalize(it.styleType, it.styleRatio);
}

int kotvWatchPosterSize(WidgetRef ref) {
  final raw = ref.watch(settingsProvider).maybeWhen(
        data: (m) => '${m['size'] ?? ''}',
        orElse: () => '',
      );
  return kotvPosterSizeValue(raw);
}

/// 横屏基数 7，竖屏 5；短边 ≥ 600 再加 1。列数 = |尺寸档 − 基数|，横图样式再减 1。
/// 电视不加这档：逻辑短边分不开 1080p 和 4K/8K，系统电视标记见 [KotvLayout.television]。
int kotvPosterColumns({
  required double width,
  required double height,
  required int size,
  required bool landStyle,
  bool television = false,
}) {
  final landscape = television || width >= height;
  var base = landscape ? 7 : 5;
  if (!television && math.min(width, height) >= 600) base += 1;
  var n = (kotvPosterSizeValue('$size') - base).abs();
  if (landStyle) n -= 1;
  if (n < 1) n = 1;
  return n;
}

/// 格子宽高比等于图片比例。名称条盖在图片上，不增加格子高度。
double kotvPosterCellAspect({required double ratio, bool oval = false}) =>
    KotvGridStyle.clampRatio(ratio, oval: oval);

/// 当前窗口下的海报网格参数。
({int columns, double aspect, double gap}) kotvPosterMetrics(
  BuildContext context, {
  required double extent,
  required KotvGridStyle style,
  required int size,
}) {
  final screen = MediaQuery.sizeOf(context);
  final gap = KotvLayout.isCompact(context) ? 6.0 : 10.0;
  final cols = !extent.isFinite || extent <= 0
      ? 1
      : kotvPosterColumns(
          width: screen.width,
          height: screen.height,
          size: size,
          landStyle: style.isLand,
          television: KotvLayout.television,
        );
  final aspect = kotvPosterCellAspect(ratio: style.ratio, oval: style.isOval);
  return (columns: cols, aspect: aspect, gap: gap);
}
