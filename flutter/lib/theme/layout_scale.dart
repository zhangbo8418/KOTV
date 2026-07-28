import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 桌面默认可缩窗口下限（可模拟手机竖/横屏）；迷你窗可临时更小。
const Size kotvMinWindowSize = Size(320, 280);

/// 对齐 Legacy 默认窗口 1280×720：随窗口宽度等比缩放布局尺寸。
/// 文字走 [MediaQuery.textScaler]；间距/高度/图标用 [s]/[of]。
class LayoutScale extends InheritedWidget {
  const LayoutScale({super.key, required this.scale, required super.child});

  static const designW = 1280.0;
  static const designH = 720.0;

  /// 相对设计稿的缩放系数（已 clamp）。
  final double scale;

  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LayoutScale>()?.scale ?? 1.0;

  /// 控件尺寸用：文字不再缩小时（scale&lt;0.85），布局也不能比文字更小，否则胶囊内部溢出。
  static double layoutOf(BuildContext context) {
    final s = of(context);
    final t = MediaQuery.textScalerOf(context).scale(1.0);
    return math.max(s, t);
  }

  /// 设计稿像素 → 当前窗口尺寸。
  static double s(BuildContext context, double designPx) => designPx * of(context);

  /// 由可用宽高计算缩放。竖/横都保持字与控件等比，避免过小导致底栏裁切字。
  static double compute(double width, [double height = designH]) {
    final byW = width / designW;
    final byH = height / designH;
    // 取宽高更紧的一边，超宽屏不会只按宽度放大到发虚。
    final v = math.min(byW, byH);
    return v.clamp(0.55, 1.35);
  }

  @override
  bool updateShouldNotify(LayoutScale oldWidget) => scale != oldWidget.scale;
}

/// 响应式布局断点：竖屏底栏 / 窄屏紧凑顶栏 / 矮屏横屏。
class KotvLayout {
  KotvLayout._();

  /// 竖屏且宽度偏窄 → 普通 App 式底部菜单。
  static bool useBottomNav(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return size.height > size.width && size.width < 900;
  }

  /// 窄屏（竖屏手机或缩得很小的桌面窗）。
  static bool isCompact(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return size.width < 720 || size.shortestSide < 560;
  }

  /// 手机横屏（宽但矮）。
  static bool isLandscapeCompact(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return size.width >= size.height && size.height < 520;
  }

  static EdgeInsets pagePadding(BuildContext context, {double desk = 28, double compact = 12}) {
    final v = isCompact(context) ? compact : desk;
    return EdgeInsets.symmetric(horizontal: v);
  }
}

/// 给子树注入缩放 + textScaler，窗口拖拽时整页比例跟手。
/// 紧凑模式（scale < 0.85）下不再缩文字，避免字被裁切/过小。
class ScaledLayoutBox extends StatelessWidget {
  const ScaledLayoutBox({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final scale = LayoutScale.compute(c.maxWidth, c.maxHeight);
        final mq = MediaQuery.of(context);
        // scale < 0.85 意味着窗口很小（竖屏/手机），此时文字保持 1.0 不缩放
        final textScale = scale < 0.85 ? 1.0 : scale;
        return LayoutScale(
          scale: scale,
          child: MediaQuery(
            data: mq.copyWith(textScaler: TextScaler.linear(textScale)),
            child: child,
          ),
        );
      },
    );
  }
}
