import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../player/tv_remote_keys.dart';

/// TV 遥控友好输入框：光标/选区到尽头时方向键离焦到相邻焦点。
class KotvTvTextField extends StatefulWidget {
  const KotvTvTextField({
    super.key,
    this.controller,
    this.focusNode,
    this.decoration,
    this.style,
    this.obscureText = false,
    this.autofocus = false,
    this.maxLines = 1,
    this.minLines,
    this.keyboardType,
    this.textInputAction,
    this.onChanged,
    this.onSubmitted,
    this.onEditingComplete,
    this.enabled,
    this.readOnly = false,
    this.showCursor,
    this.inputFormatters,
    this.cursorColor,
    this.textAlign = TextAlign.start,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final InputDecoration? decoration;
  final TextStyle? style;
  final bool obscureText;
  final bool autofocus;
  final int? maxLines;
  final int? minLines;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onEditingComplete;
  final bool? enabled;
  final bool readOnly;
  final bool? showCursor;
  final List<TextInputFormatter>? inputFormatters;
  final Color? cursorColor;
  final TextAlign textAlign;

  @override
  State<KotvTvTextField> createState() => _KotvTvTextFieldState();
}

class _KotvTvTextFieldState extends State<KotvTvTextField> {
  TextEditingController? _ownedController;
  FocusNode? _ownedFocus;
  FocusNode? _boundExternalFocus;
  KeyEventResult Function(FocusNode, KeyEvent)? _prevOnKeyEvent;

  TextEditingController get _controller => widget.controller ?? _ownedController!;
  FocusNode get _focusNode => widget.focusNode ?? _ownedFocus!;

  bool get _singleLine => (widget.maxLines ?? 1) == 1;

  @override
  void initState() {
    super.initState();
    if (widget.controller == null) {
      _ownedController = TextEditingController();
    }
    if (widget.focusNode == null) {
      _ownedFocus = FocusNode(debugLabel: 'KotvTvTextField', onKeyEvent: _onKey);
    } else {
      _bindExternal(widget.focusNode!);
    }
  }

  @override
  void didUpdateWidget(KotvTvTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      _unbindExternal();
      if (widget.focusNode == null) {
        _ownedFocus ??= FocusNode(debugLabel: 'KotvTvTextField', onKeyEvent: _onKey);
      } else {
        _ownedFocus?.dispose();
        _ownedFocus = null;
        _bindExternal(widget.focusNode!);
      }
    }
  }

  void _bindExternal(FocusNode node) {
    _boundExternalFocus = node;
    _prevOnKeyEvent = node.onKeyEvent;
    node.onKeyEvent = (n, e) {
      final r = _onKey(n, e);
      if (r != KeyEventResult.ignored) return r;
      return _prevOnKeyEvent?.call(n, e) ?? KeyEventResult.ignored;
    };
  }

  void _unbindExternal() {
    final node = _boundExternalFocus;
    if (node != null) {
      node.onKeyEvent = _prevOnKeyEvent;
    }
    _boundExternalFocus = null;
    _prevOnKeyEvent = null;
  }

  @override
  void dispose() {
    _unbindExternal();
    _ownedController?.dispose();
    _ownedFocus?.dispose();
    super.dispose();
  }

  bool _caretAtTextStart(TextSelection sel) {
    if (!sel.isValid) return true;
    return sel.start <= 0 && sel.end <= 0;
  }

  bool _caretAtTextEnd(TextSelection sel, String text) {
    if (!sel.isValid) return true;
    final n = text.length;
    return sel.start >= n && sel.end >= n;
  }

  bool _onFirstLine(TextSelection sel, String text) {
    if (_singleLine) return true;
    if (!sel.isValid) return true;
    final before = text.substring(0, sel.start.clamp(0, text.length));
    return !before.contains('\n');
  }

  bool _onLastLine(TextSelection sel, String text) {
    if (_singleLine) return true;
    if (!sel.isValid) return true;
    final after = text.substring(sel.end.clamp(0, text.length));
    return !after.contains('\n');
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final text = _controller.text;
    final sel = _controller.selection;

    TraversalDirection? dir;
    if (kotvIsLeftKey(key) && _caretAtTextStart(sel)) {
      dir = TraversalDirection.left;
    } else if (kotvIsRightKey(key) && _caretAtTextEnd(sel, text)) {
      dir = TraversalDirection.right;
    } else if (kotvIsUpKey(key) && _onFirstLine(sel, text)) {
      dir = TraversalDirection.up;
    } else if (kotvIsDownKey(key) && _onLastLine(sel, text)) {
      dir = TraversalDirection.down;
    }

    if (dir == null) return KeyEventResult.ignored;
    final moved = node.focusInDirection(dir);
    return moved ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      focusNode: _focusNode,
      decoration: widget.decoration,
      style: widget.style,
      obscureText: widget.obscureText,
      autofocus: widget.autofocus,
      maxLines: widget.maxLines,
      minLines: widget.minLines,
      keyboardType: widget.keyboardType,
      textInputAction: widget.textInputAction,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      onEditingComplete: widget.onEditingComplete,
      enabled: widget.enabled,
      readOnly: widget.readOnly,
      showCursor: widget.showCursor,
      inputFormatters: widget.inputFormatters,
      cursorColor: widget.cursorColor,
      textAlign: widget.textAlign,
    );
  }
}
