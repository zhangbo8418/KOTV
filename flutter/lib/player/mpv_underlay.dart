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

/// 播放洞：几何 `updateFrame`；显隐 `setVisible`（macOS 开播后不因遮罩藏层）。
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
  bool? _lastVisible;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  @override
  void dispose() {
    _setVisible(false);
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
    if (!kotvIsMacOS() && !kotvIsWindows()) return;
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
    if (_lastOrigin != origin || _lastSize != size) {
      _lastOrigin = origin;
      _lastSize = size;
      _updateFrame(origin & size);
    }
    // 桌面 underlay/HWND：loadfile 期间藏原生层会丢帧。未就绪只用 Flutter 黑遮。
    if (kotvIsMacOS() || kotvIsWindows()) {
      if (widget.ready && !widget.coverUntilReady) {
        _setVisible(true);
      }
      return;
    }
    _setVisible(widget.ready && !widget.coverUntilReady);
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
        child: ColoredBox(
          color: cover ? Colors.black : Colors.transparent,
        ),
      ),
    );
  }
}
