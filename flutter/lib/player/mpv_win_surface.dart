import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Windows HWND 硬渲占位：同步子窗口 bounds 给原生 MPV（对齐 Android Surface）。
class KotvMpvWinSurfaceHost extends StatefulWidget {
  const KotvMpvWinSurfaceHost({super.key});

  static const _ch = MethodChannel('kotv_mpv');

  @override
  State<KotvMpvWinSurfaceHost> createState() => _KotvMpvWinSurfaceHostState();
}

class _KotvMpvWinSurfaceHostState extends State<KotvMpvWinSurfaceHost> {
  Rect? _last;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncBounds());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncBounds());
  }

  Future<void> _syncBounds() async {
    if (!Platform.isWindows || !mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final offset = box.localToGlobal(Offset.zero);
    final size = box.size;
    final next = Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height);
    if (_last != null &&
        (_last!.left - next.left).abs() < 0.5 &&
        (_last!.top - next.top).abs() < 0.5 &&
        (_last!.width - next.width).abs() < 0.5 &&
        (_last!.height - next.height).abs() < 0.5) {
      return;
    }
    _last = next;
    try {
      await KotvMpvWinSurfaceHost._ch.invokeMethod('updateSurfaceBounds', {
        'x': next.left,
        'y': next.top,
        'width': next.width,
        'height': next.height,
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _syncBounds());
        return const SizedBox.expand();
      },
    );
  }
}
