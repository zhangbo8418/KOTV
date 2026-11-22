import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'kotv_platform.dart';

/// 下发视频 HWND 几何（逻辑像素 + 可选 dpr）。Win7 详情内嵌与 Hole 共用。
Future<void> kotvMpvUpdateVideoFrame({
  required double x,
  required double y,
  required double w,
  required double h,
  double? dpr,
}) async {
  if (w < 8 || h < 8) return;
  try {
    await const MethodChannel('kotv_mpv').invokeMethod('updateFrame', {
      'x': x,
      'y': y,
      'w': w,
      'h': h,
      if (dpr != null && dpr > 0) 'dpr': dpr,
    });
  } catch (_) {}
}

/// Win7：强制洞矩形（视图逻辑坐标），与 chrome surface/slot 同源，避免自测漂移。
class KotvMpvForcedGeom extends InheritedWidget {
  const KotvMpvForcedGeom({
    super.key,
    required this.globalRect,
    required super.child,
  });

  final Rect? globalRect;

  static Rect? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<KotvMpvForcedGeom>()?.globalRect;
  }

  @override
  bool updateShouldNotify(covariant KotvMpvForcedGeom oldWidget) {
    final a = globalRect;
    final b = oldWidget.globalRect;
    if (identical(a, b)) return false;
    if (a == null || b == null) return a != b;
    return (a.left - b.left).abs() > 0.5 ||
        (a.top - b.top).abs() > 0.5 ||
        (a.width - b.width).abs() > 0.5 ||
        (a.height - b.height).abs() > 0.5;
  }
}

/// macOS ASBDL / Win8+ DComp：画面在 Flutter 之下，洞须 clear。
bool kotvMpvUsesUnderlayHole() =>
    kotvUsesNativeMpv() &&
    (kotvIsMacOS() || kotvUsesWindowsDcompUnderlay());

/// 视频栈 letterbox：underlay 洞必须透明，否则挡住下层视频；其它平台黑底。
Widget kotvMpvLetterboxFill({Key? key}) => ColoredBox(
      key: key,
      color: kotvMpvUsesUnderlayHole() ? Colors.transparent : Colors.black,
    );

/// Win7 库存引擎：可选全局裁剪（与顶栏下内容区求交后 MoveWindow）。
/// Win8+ DComp 不需要（Flutter 已盖住视频）。
class KotvMpvUnderlayClip extends InheritedWidget {
  const KotvMpvUnderlayClip({
    super.key,
    required this.globalClip,
    required super.child,
  });

  final Rect? globalClip;

  static Rect? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<KotvMpvUnderlayClip>()?.globalClip;
  }

  @override
  bool updateShouldNotify(covariant KotvMpvUnderlayClip oldWidget) {
    final a = globalClip;
    final b = oldWidget.globalClip;
    if (identical(a, b)) return false;
    if (a == null || b == null) return a != b;
    return (a.left - b.left).abs() > 0.5 ||
        (a.top - b.top).abs() > 0.5 ||
        (a.width - b.width).abs() > 0.5 ||
        (a.height - b.height).abs() > 0.5;
  }
}

/// 旧：Win7 全屏曾用 inset 给顶/底栏留黑边。现改为栏叠视频，保留函数仅兼容旧调用。
@Deprecated('Win7 fullscreen chrome overlays video; do not inset the HWND')
Rect kotvWindowsOverlayFullscreenInset(Rect full, {bool episodesOpen = false}) {
  return full;
}

/// 播放洞：下发几何 `updateFrame`；未就绪黑遮。
/// underlay（macOS / Win8+ DComp）：显隐由原生 open/stop；就绪后 [BlendMode.clear]。
/// Win7：仍经 `setVisible`；弹窗时藏层。
class KotvMpvUnderlayHole extends StatefulWidget {
  const KotvMpvUnderlayHole({
    super.key,
    required this.ready,
    required this.coverUntilReady,
  });

  final bool ready;
  final bool coverUntilReady;

  static final ValueNotifier<int> _resync = ValueNotifier<int>(0);

  /// 祖先只改了摆放位置、洞本身不重建时（如全屏上下滑切集画面跟手），下一帧重新下发几何。
  static void resyncAll() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _resync.value++);
  }

  @override
  State<KotvMpvUnderlayHole> createState() => _KotvMpvUnderlayHoleState();
}

class _KotvMpvUnderlayHoleState extends State<KotvMpvUnderlayHole> {
  static const _ch = MethodChannel('kotv_mpv');
  Offset? _lastOrigin;
  Size? _lastSize;
  Rect? _lastSent;
  bool? _lastVisible;

  bool get _win7Overlay => kotvUsesWindowsNativeChrome();

  @override
  void initState() {
    super.initState();
    KotvMpvUnderlayHole._resync.addListener(_sync);
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  @override
  void dispose() {
    KotvMpvUnderlayHole._resync.removeListener(_sync);
    if (_win7Overlay) {
      _setVisible(false);
    }
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant KotvMpvUnderlayHole oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  Future<void> _setVisible(bool visible) async {
    if (_lastVisible == visible) return;
    _lastVisible = visible;
    if (!_win7Overlay) return;
    try {
      await _ch.invokeMethod('setVisible', {'visible': visible});
    } catch (_) {}
  }

  Future<void> _updateFrame(Rect r) async {
    try {
      final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
      await _ch.invokeMethod('updateFrame', {
        'x': r.left,
        'y': r.top,
        'w': r.width,
        'h': r.height,
        'dpr': dpr,
      });
    } catch (_) {}
  }

  Future<void> _syncAsync() async {
    if (!mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;

    // Win7：路由被盖住时藏 HWND，避免挡住对话框。
    final route = ModalRoute.of(context);
    if (_win7Overlay && route != null && !route.isCurrent) {
      await _setVisible(false);
      return;
    }

    final origin = box.localToGlobal(Offset.zero);
    final size = box.size;
    var hole = origin & size;

    if (_win7Overlay) {
      // 详情内嵌优先用槽/surface 覆盖几何（与 chrome 同源），避免洞自测漂移。
      final forced = KotvMpvForcedGeom.maybeOf(context);
      if (forced != null && forced.width >= 8 && forced.height >= 8) {
        hole = forced;
      } else {
        final clip = KotvMpvUnderlayClip.maybeOf(context);
        if (clip != null) {
          hole = hole.intersect(clip);
        }
      }
    }

    final moved = _lastOrigin != origin || _lastSize != size;
    _lastOrigin = origin;
    _lastSize = size;

    if (hole.width < 1 || hole.height < 1) {
      if (_win7Overlay) await _setVisible(false);
      return;
    }

    final sameSent = _lastSent != null &&
        (_lastSent!.left - hole.left).abs() < 0.5 &&
        (_lastSent!.top - hole.top).abs() < 0.5 &&
        (_lastSent!.width - hole.width).abs() < 0.5 &&
        (_lastSent!.height - hole.height).abs() < 0.5;
    if (!sameSent || moved) {
      _lastSent = hole;
      await _updateFrame(hole);
    }

    if (_win7Overlay) {
      if (widget.ready && !widget.coverUntilReady) {
        await _setVisible(true);
      }
    }
  }

  void _sync() {
    unawaited(_syncAsync());
  }

  @override
  Widget build(BuildContext context) {
    final cover = !widget.ready || widget.coverUntilReady;
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
    return NotificationListener<SizeChangedLayoutNotification>(
      onNotification: (_) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
        return false;
      },
      child: SizeChangedLayoutNotifier(
        child: cover
            ? const ColoredBox(color: Colors.black)
            : (kotvMpvUsesUnderlayHole()
                ? const CustomPaint(
                    painter: _KotvUnderlayClearPainter(),
                    child: SizedBox.expand(),
                  )
                // Win7：无 underlay，洞区透给下层无意义；黑/透明均可，HWND 盖在上面。
                : const ColoredBox(color: Colors.transparent)),
      ),
    );
  }
}

/// 清成本矩形透明，露出下层视频（ASBDL / DComp child）。
class _KotvUnderlayClearPainter extends CustomPainter {
  const _KotvUnderlayClearPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..blendMode = BlendMode.clear,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
