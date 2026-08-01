import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// 桌面端允许鼠标拖动滚动（Flutter 默认仅触摸/触控板）。
class KotvScrollBehavior extends MaterialScrollBehavior {
  const KotvScrollBehavior({this.showScrollbar = true});

  final bool showScrollbar;

  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
        PointerDeviceKind.unknown,
      };

  @override
  Widget buildScrollbar(BuildContext context, Widget child, ScrollableDetails details) {
    if (!showScrollbar) return child;
    return super.buildScrollbar(context, child, details);
  }
}

/// 横向列表：鼠标拖动 + 滚轮（上下也映射为左右）。
class HScrollList extends StatefulWidget {
  const HScrollList({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.separatorBuilder,
    this.padding,
    this.physics,
  });

  final int itemCount;
  final NullableIndexedWidgetBuilder itemBuilder;
  final IndexedWidgetBuilder? separatorBuilder;
  final EdgeInsetsGeometry? padding;
  final ScrollPhysics? physics;

  @override
  State<HScrollList> createState() => _HScrollListState();
}

class _HScrollListState extends State<HScrollList> {
  final _sc = ScrollController();

  @override
  void dispose() {
    _sc.dispose();
    super.dispose();
  }

  void _onWheel(PointerSignalEvent e) {
    if (e is! PointerScrollEvent || !_sc.hasClients) return;
    final delta = e.scrollDelta.dx != 0 ? e.scrollDelta.dx : e.scrollDelta.dy;
    if (delta == 0) return;
    final pos = _sc.position;
    _sc.jumpTo((_sc.offset + delta).clamp(pos.minScrollExtent, pos.maxScrollExtent));
  }

  @override
  Widget build(BuildContext context) {
    final list = widget.separatorBuilder != null
        ? ListView.separated(
            controller: _sc,
            scrollDirection: Axis.horizontal,
            padding: widget.padding,
            physics: widget.physics,
            itemCount: widget.itemCount,
            separatorBuilder: widget.separatorBuilder!,
            itemBuilder: widget.itemBuilder,
          )
        : ListView.builder(
            controller: _sc,
            scrollDirection: Axis.horizontal,
            padding: widget.padding,
            physics: widget.physics,
            itemCount: widget.itemCount,
            itemBuilder: widget.itemBuilder,
          );

    return ScrollConfiguration(
      behavior: const KotvScrollBehavior(showScrollbar: false),
      child: Listener(
        onPointerSignal: _onWheel,
        child: list,
      ),
    );
  }
}

/// 包装已有横向 [ListView] / [SingleChildScrollView]，仅补桌面拖动（无自管 controller）。
class HScroll extends StatelessWidget {
  const HScroll({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ScrollConfiguration(
      behavior: const KotvScrollBehavior(showScrollbar: false),
      child: child,
    );
  }
}
