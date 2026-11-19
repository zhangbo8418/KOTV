import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'kotv_platform.dart';

/// macOS underlay：画面在 Flutter 视图之下；letterbox 黑底会挡住 ASBDL，必须透明。
/// Win HWND / Android Surface 画在洞上或同层，仍可用黑底填 letterbox。
bool kotvMpvUnderlayLetterboxMustBeClear() => kotvUsesNativeMpv() && kotvIsMacOS();

/// 详情/直播 letterbox 底：underlay 用透明，其它平台用黑。
Widget kotvMpvLetterboxFill({Key? key}) => ColoredBox(
      key: key,
      color: kotvMpvUnderlayLetterboxMustBeClear() ? Colors.transparent : Colors.black,
    );

/// 桌面 underlay：播放洞透明穿透 + 换集黑遮罩。
///
/// 矩形/可见性经 `kotv_mpv` 的 `updateFrame` / `setVisible` 下发（详情/直播共用）。
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
    final show = widget.ready && !widget.coverUntilReady;
    if (_lastOrigin != origin || _lastSize != size) {
      _lastOrigin = origin;
      _lastSize = size;
      _updateFrame(origin & size);
    }
    _setVisible(show);
  }

  @override
  Widget build(BuildContext context) {
    final opaque = !widget.ready || widget.coverUntilReady;
    return NotificationListener<SizeChangedLayoutNotification>(
      onNotification: (_) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
        return false;
      },
      child: SizeChangedLayoutNotifier(
        child: ColoredBox(
          color: opaque ? Colors.black : Colors.transparent,
        ),
      ),
    );
  }
}
