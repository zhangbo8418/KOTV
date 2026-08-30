import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../player/fullscreen_mode.dart';
import '../player/kotv_platform.dart';
import '../theme/kotv_theme.dart';

/// 播放器全屏按钮：移动端直接进入；桌面在图标上方弹出抽屉式选项。
class KotvFullscreenExpandButton extends StatefulWidget {
  const KotvFullscreenExpandButton({
    super.key,
    required this.onSelect,
    this.size = 40,
    this.iconSize,
    /// 为 null 时：桌面/Web 弹出「铺满窗口 / 占满屏幕」；其它平台直接进应用内全屏。
    /// 竖屏等场景可显式传 false，避免多余的「全窗口」选项。
    this.offerDisplayChoice,
  });

  final ValueChanged<KotvDesktopFullscreenKind> onSelect;
  final double size;
  final double? iconSize;
  final bool? offerDisplayChoice;

  @override
  State<KotvFullscreenExpandButton> createState() => _KotvFullscreenExpandButtonState();
}

class _KotvFullscreenExpandButtonState extends State<KotvFullscreenExpandButton> {
  final LayerLink _link = LayerLink();
  OverlayEntry? _entry;
  bool _open = false;

  @override
  void dispose() {
    _removeOverlay();
    super.dispose();
  }

  void _removeOverlay() {
    _entry?.remove();
    _entry = null;
    _open = false;
  }

  void _close() {
    if (!_open) return;
    _removeOverlay();
  }

  void _pick(KotvDesktopFullscreenKind kind) {
    _close();
    widget.onSelect(kind);
  }

  /// 桌面与 Web 默认可选「铺满窗口 / 占满屏幕」；可由 [offerDisplayChoice] 关闭。
  bool get _offerDisplayChoice =>
      widget.offerDisplayChoice ?? (kotvIsDesktop() || kIsWeb);

  void _onTap() {
    if (!_offerDisplayChoice) {
      widget.onSelect(KotvDesktopFullscreenKind.window);
      return;
    }
    if (_open) {
      _close();
      return;
    }
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) {
      widget.onSelect(KotvDesktopFullscreenKind.window);
      return;
    }
    _open = true;
    _entry = OverlayEntry(
      builder: (ctx) {
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _close,
              ),
            ),
            CompositedTransformFollower(
              link: _link,
              showWhenUnlinked: false,
              targetAnchor: Alignment.topCenter,
              followerAnchor: Alignment.bottomCenter,
              offset: const Offset(0, -8),
              child: Material(
                color: Colors.transparent,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xF214101C),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white.withOpacity(0.14)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.45),
                        blurRadius: 18,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: IntrinsicWidth(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _item(
                          icon: Icons.crop_din_rounded,
                          label: '铺满当前窗口',
                          kind: KotvDesktopFullscreenKind.window,
                        ),
                        Container(height: 1, color: Colors.white.withOpacity(0.08)),
                        _item(
                          icon: Icons.fullscreen_rounded,
                          label: '占满整块屏幕',
                          kind: KotvDesktopFullscreenKind.display,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
    overlay.insert(_entry!);
  }

  Widget _item({
    required IconData icon,
    required String label,
    required KotvDesktopFullscreenKind kind,
  }) {
    return InkWell(
      onTap: () => _pick(kind),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: Colors.white.withOpacity(0.92)),
            const SizedBox(width: 10),
            Text(
              label,
              style: TextStyle(
                color: Colors.white.withOpacity(0.95),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final iconSz = widget.iconSize ?? (widget.size <= 34 ? 18.0 : 22.0);
    return CompositedTransformTarget(
      link: _link,
      child: Tooltip(
        message: '全屏',
        child: TvFocus(
          onPressed: _onTap,
          borderRadius: 8,
          child: SizedBox(
            width: widget.size,
            height: widget.size,
            child: Icon(Icons.fullscreen, color: Colors.white, size: iconSz),
          ),
        ),
      ),
    );
  }
}
