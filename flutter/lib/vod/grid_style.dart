import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../providers.dart';
import '../theme/layout_scale.dart';

/// 海报标题区高度（设计像素）。图片在上，标题在下。
const double kotvPosterTitleDesign = 36;

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

/// 格子宽高比：图片高 = 宽 / ratio，标题在图片下面。
double kotvPosterCellAspect({
  required double extent,
  required int columns,
  required double gap,
  required double ratio,
  required double titleHeight,
}) {
  final r = KotvGridStyle.clampRatio(ratio, oval: false);
  if (extent <= 0 || columns < 1) return r;
  final cellW = (extent - gap * (columns - 1)) / columns;
  if (cellW <= 0) return r;
  final title = titleHeight < 0 ? 0.0 : titleHeight;
  return cellW / (cellW / r + title);
}

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
  final aspect = kotvPosterCellAspect(
    extent: extent.isFinite ? extent : 0,
    columns: cols,
    gap: gap,
    ratio: style.ratio,
    titleHeight: kotvPosterTitleDesign * LayoutScale.of(context),
  );
  return (columns: cols, aspect: aspect, gap: gap);
}
