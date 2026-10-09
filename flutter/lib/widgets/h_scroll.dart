import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

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
/// 打开时停在 [scrollToIndex]。[itemStride] 已知则首帧就在该项；宽度随文字变化时，先按布局量出起点再跳过去。
class HScrollList extends StatefulWidget {
  const HScrollList({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.separatorBuilder,
    this.padding,
    this.physics,
    this.scrollToIndex,
    this.itemStride,
  });

  final int itemCount;
  final NullableIndexedWidgetBuilder itemBuilder;
  final IndexedWidgetBuilder? separatorBuilder;
  final EdgeInsetsGeometry? padding;
  final ScrollPhysics? physics;
  final int? scrollToIndex;
  /// 每项占位（含间距）。为空时按子组件布局结果定位。
  final double? itemStride;

  @override
  State<HScrollList> createState() => _HScrollListState();
}

class _HScrollListState extends State<HScrollList> {
  late final KotvJumpController _sc = KotvJumpController(initialOffset: _offset(widget.scrollToIndex));
  final GlobalKey _selKey = GlobalKey();
  int? _pendingIndex;
  var _hideUntilPlaced = false;
  var _placeTries = 0;
  var _placed = false;

  bool get _measure => widget.itemStride == null && widget.scrollToIndex != null && widget.scrollToIndex! > 0;

  double _offset(int? index) {
    final stride = widget.itemStride;
    if (index == null || index <= 0 || stride == null || stride <= 0) return 0;
    return index * stride;
  }

  @override
  void initState() {
    super.initState();
    final index = widget.scrollToIndex;
    if (_measure) {
      _hideUntilPlaced = true;
      _queuePlace(index);
    } else {
      // 打开时没有待定位的项。之后的点选只改高亮，不再把该项拉到前缘。
      _placed = true;
    }
  }

  @override
  void didUpdateWidget(HScrollList oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 打开时把正在用的项放进视口。点选之后不再改滚动位置。
    if (_placed) return;
    final index = widget.scrollToIndex;
    if (index == null || index <= 0) return;
    if (widget.itemStride != null) {
      _pendingIndex = null;
      _hideUntilPlaced = false;
      _placed = true;
      _sc.reveal(_offset(index));
      return;
    }
    _queuePlace(index);
  }

  void _queuePlace(int? index) {
    if (index == null || index <= 0 || widget.itemStride != null) {
      _pendingIndex = null;
      _hideUntilPlaced = false;
      return;
    }
    _pendingIndex = index;
    _placeTries = 0;
    WidgetsBinding.instance.addPostFrameCallback((_) => _placePending());
  }

  void _placePending() {
    final index = _pendingIndex;
    if (!mounted || index == null || index != widget.scrollToIndex) return;
    final object = _selKey.currentContext?.findRenderObject();
    final viewport = object == null ? null : RenderAbstractViewport.maybeOf(object);
    if (object is! RenderBox || !object.hasSize || viewport == null || !_sc.hasClients || !_sc.position.hasContentDimensions) {
      if (_placeTries++ < 4) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _placePending());
        return;
      }
      _pendingIndex = null;
      _hideUntilPlaced = false;
      _placed = true;
      if (mounted) setState(() {});
      return;
    }
    final target = viewport.getOffsetToReveal(object, 0.0).offset;
    _pendingIndex = null;
    _hideUntilPlaced = false;
    _placed = true;
    _sc.reveal(target);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _sc.dispose();
    super.dispose();
  }

  Widget? _buildItem(BuildContext context, int i) {
    final child = widget.itemBuilder(context, i);
    // 定位完成后不再套 GlobalKey。选中项一变，这把钥匙会跟着挪，焦点就被带到新下标上。
    if (child == null || !_measure || _placed || i != widget.scrollToIndex) return child;
    return KeyedSubtree(key: _selKey, child: child);
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
            cacheExtent: _measure ? 1000000 : null,
            padding: widget.padding,
            physics: widget.physics,
            itemCount: widget.itemCount,
            separatorBuilder: widget.separatorBuilder!,
            itemBuilder: _buildItem,
          )
        : ListView.builder(
            controller: _sc,
            scrollDirection: Axis.horizontal,
            cacheExtent: _measure ? 1000000 : null,
            padding: widget.padding,
            physics: widget.physics,
            itemCount: widget.itemCount,
            itemBuilder: _buildItem,
          );

    return ScrollConfiguration(
      behavior: const KotvScrollBehavior(showScrollbar: false),
      child: Listener(
        onPointerSignal: _onWheel,
        child: IgnorePointer(
          ignoring: _hideUntilPlaced,
          child: Opacity(
            opacity: _hideUntilPlaced ? 0 : 1,
            child: list,
          ),
        ),
      ),
    );
  }
}

/// 列表打开时直接停在指定偏移，不从开头滑过去。
class KotvJumpController extends ScrollController {
  KotvJumpController({double initialOffset = 0})
      : _offset = initialOffset < 0 ? 0 : initialOffset,
        super(initialScrollOffset: initialOffset < 0 ? 0 : initialOffset, keepScrollOffset: false);

  double _offset;

  void arm(double offset) {
    _offset = offset < 0 ? 0 : offset;
  }

  void reveal(double offset) {
    arm(offset);
    if (!hasClients || !position.hasContentDimensions) return;
    final pos = position;
    final target = _offset.clamp(pos.minScrollExtent, pos.maxScrollExtent);
    if ((pos.pixels - target).abs() < 0.5) return;
    pos.jumpTo(target);
  }

  @override
  ScrollPosition createScrollPosition(ScrollPhysics physics, ScrollContext context, ScrollPosition? oldPosition) {
    return ScrollPositionWithSingleContext(
      physics: physics,
      context: context,
      initialPixels: _offset,
      keepScrollOffset: keepScrollOffset,
      oldPosition: oldPosition,
      debugLabel: debugLabel,
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
