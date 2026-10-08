import 'package:flutter/widgets.dart';

import 'kotv_theme.dart';

/// 按键持有焦点节点。选中态只改外观，不换节点。
class KotvFocusBag {
  final Map<String, FocusNode> _nodes = {};

  FocusNode of(String key) => _nodes.putIfAbsent(key, () => FocusNode(debugLabel: key));

  void dispose() {
    for (final n in _nodes.values) {
      n.dispose();
    }
    _nodes.clear();
  }
}

/// 一行一个焦点节点，创建时记下是否自动获焦，之后选中变化不再改这个节点。
class KotvStableFocus extends StatefulWidget {
  const KotvStableFocus({
    super.key,
    required this.child,
    this.onPressed,
    this.onLongPress,
    this.autofocus = false,
    this.borderRadius = 12,
    this.scrollIntoView = false,
  });

  final Widget child;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final bool autofocus;
  final double borderRadius;
  final bool scrollIntoView;

  @override
  State<KotvStableFocus> createState() => _KotvStableFocusState();
}

class _KotvStableFocusState extends State<KotvStableFocus> {
  final FocusNode _node = FocusNode();
  late final bool _autofocus;

  @override
  void initState() {
    super.initState();
    _autofocus = widget.autofocus;
  }

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TvFocus(
      focusNode: _node,
      autofocus: _autofocus,
      onPressed: widget.onPressed,
      onLongPress: widget.onLongPress,
      borderRadius: widget.borderRadius,
      scrollIntoView: widget.scrollIntoView,
      child: widget.child,
    );
  }
}
