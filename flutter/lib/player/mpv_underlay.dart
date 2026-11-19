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
    if (oldWidget.ready != widget.ready ||
        oldWidget.coverUntilReady != widget.coverUntilReady) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
    }
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
    final origin = box.localToGlobal(Offset.zero);
    final size = box.size;
    // 每次都下发：core 重建时几何未变但原生 pending 可能刚清空。
    _updateFrame(origin & size);
    // Win：就绪后显 HWND。macOS：原生 open/首帧负责显层；未就绪只用 Flutter 黑遮。
    if (kotvIsWindows()) {
      if (widget.ready && !widget.coverUntilReady) {
        _setVisible(true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cover = !widget.ready || widget.coverUntilReady;
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
