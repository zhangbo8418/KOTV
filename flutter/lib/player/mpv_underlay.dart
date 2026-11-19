import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'kotv_platform.dart';

/// macOS / 桌面 underlay：播放洞透明穿透 + 换集黑遮罩，避免漏底。
///
/// 矩形与可见性经 `kotv_mpv` 的 `updateFrame` / `setVisible` 下发（单点，供详情/直播共用）。
class KotvMpvUnderlayHole extends StatefulWidget {
  const KotvMpvUnderlayHole({
    super.key,
    required this.ready,
    required this.coverUntilReady,
  });

  /// 已出画（playback-restart / ready）后为 true，洞才透明。
  final bool ready;

  /// 换集/加载期强制不透明黑，防止漏桌面。
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
  void dispose() {
    _setVisible(false);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant KotvMpvUnderlayHole oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  Future<void> _setVisible(bool visible) async {
    if (_lastVisible == visible) return;
    _lastVisible = visible;
    if (!kotvIsMacOS() && !kotvIsWindows() && !kotvIsIOS()) return;
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
    final moved = _lastOrigin != origin || _lastSize != size;
    if (moved) {
      _lastOrigin = origin;
      _lastSize = size;
      _updateFrame(origin & size);
    }
    _setVisible(show);
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
    final opaque = !widget.ready || widget.coverUntilReady;
    return ColoredBox(
      color: opaque ? Colors.black : Colors.transparent,
    );
  }
}
