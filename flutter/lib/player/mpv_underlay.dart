import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'kotv_platform.dart';

/// macOS：画面在 Flutter 之下（contentView.layer 底 ASBDL）。
bool kotvMpvUsesUnderlayHole() => kotvUsesNativeMpv() && kotvIsMacOS();

/// 视频栈 letterbox：macOS underlay 必须透明，否则挡住 ASBDL；其它平台黑底。
Widget kotvMpvLetterboxFill({Key? key}) => ColoredBox(
      key: key,
      color: kotvMpvUsesUnderlayHole() ? Colors.transparent : Colors.black,
    );

/// 可选：原生洞的全局裁剪矩形（窗口逻辑坐标）。
/// Windows 子 HWND 画在 Flutter 之上，须与顶栏下内容区求交，否则会盖住顶栏/弹窗。
class KotvMpvUnderlayClip extends InheritedWidget {
  const KotvMpvUnderlayClip({
    super.key,
    required this.globalClip,
    required super.child,
  });

  /// 允许露出视频的全局矩形；null 表示不额外裁剪。
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

/// 播放洞：下发几何 `updateFrame`；未就绪黑遮。
/// macOS 显隐只由原生 open/stop 驱动；Win 仍经通道 `setVisible`。
/// 就绪后须 [BlendMode.clear] 清掉同帧已画像素，单靠 transparent 透不出 ASBDL。
class KotvMpvUnderlayHole extends StatefulWidget {
  const KotvMpvUnderlayHole({
    super.key,
    required this.ready,
    required this.coverUntilReady,
  });

  final bool ready;
  final bool coverUntilReady;

  @override
  State<KotvMpvUnderlayHole> createState() => _KotvMpvUnderlayHoleState();
}

class _KotvMpvUnderlayHoleState extends State<KotvMpvUnderlayHole> {
  static const _ch = MethodChannel('kotv_mpv');
  Offset? _lastOrigin;
  Size? _lastSize;
  Rect? _lastSent;
  bool? _lastVisible;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  @override
  void dispose() {
    if (!kotvIsMacOS()) {
      _setVisible(false);
    }
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant KotvMpvUnderlayHole oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 父级 Positioned 位移也会走到这里；不能只盯 ready/cover。
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
    if (!kotvIsWindows()) return;
    try {
      await _ch.invokeMethod('setVisible', {'visible': visible});
    } catch (_) {}
  }

  Future<void> _updateFrame(Rect r) async {
    try {
      await _ch.invokeMethod('updateFrame', {
        'x': r.left,
        'y': r.top,
        'w': r.width,
        'h': r.height,
      });
    } catch (_) {}
  }

  void _sync() {
    if (!mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;

    // 弹窗等路由盖在详情上时：Win HWND 在 Flutter 之上，必须藏层，否则挡住对话框。
    final route = ModalRoute.of(context);
    if (kotvIsWindows() && route != null && !route.isCurrent) {
      _setVisible(false);
      return;
    }

    final origin = box.localToGlobal(Offset.zero);
    final size = box.size;
    var hole = origin & size;

    final clip = KotvMpvUnderlayClip.maybeOf(context);
    if (clip != null) {
      hole = hole.intersect(clip);
    }

    final moved = _lastOrigin != origin || _lastSize != size;
    _lastOrigin = origin;
    _lastSize = size;

    if (hole.width < 1 || hole.height < 1) {
      if (kotvIsWindows()) _setVisible(false);
      return;
    }

    final sameSent = _lastSent != null &&
        (_lastSent!.left - hole.left).abs() < 0.5 &&
        (_lastSent!.top - hole.top).abs() < 0.5 &&
        (_lastSent!.width - hole.width).abs() < 0.5 &&
        (_lastSent!.height - hole.height).abs() < 0.5;
    // 位移或裁剪变化都要下发；尺寸未变但 origin 变时 SizeChangedLayoutNotifier 不会响。
    if (!sameSent || moved) {
      _lastSent = hole;
      _updateFrame(hole);
    }

    if (kotvIsWindows()) {
      if (widget.ready && !widget.coverUntilReady) {
        _setVisible(true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cover = !widget.ready || widget.coverUntilReady;
    // 每帧后核对全局原点：仅靠 SizeChangedLayoutNotifier 感知不到平移。
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
    return NotificationListener<SizeChangedLayoutNotification>(
      onNotification: (_) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
        return false;
      },
      child: SizeChangedLayoutNotifier(
        child: cover
            ? const ColoredBox(color: Colors.black)
            : const CustomPaint(
                painter: _KotvUnderlayClearPainter(),
                child: SizedBox.expand(),
              ),
      ),
    );
  }
}

/// 把本矩形清成透明，露出 contentView.layer 下的视频层。
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
