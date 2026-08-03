import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import 'kotv_palette.dart';

/// 对齐 Legacy lumen 默认色板（兼容旧引用；新代码优先 [KotvPalette.of]）。
class KotvColors {
  static const bg = Color(0xFF243DD0);
  static const surface = Color(0xFF63248A);
  static const variant = Color(0xFF653AA8);
  static const primary = Color(0xFFCF4274);
  static const onPrimary = Color(0xFFFFFFFF);
  static const fg = Color(0xFFFFFFFF);
  static const muted = Color(0xD8FFFFFF);
  static const outline = Color(0xB0D8A5E8);
  static const input = Color(0xFF582D91);
  static const posterPlaceholder = Color(0xFF3A1A6E);
  static const focus = Color(0xFFFFD54F);
}

ThemeData buildKotvTheme([KotvPalette palette = KotvPalette.defaults]) {
  final scheme = ColorScheme(
    brightness: palette.light ? Brightness.light : Brightness.dark,
    primary: palette.primary,
    onPrimary: palette.light ? Colors.white : palette.fg,
    secondary: palette.variant,
    onSecondary: palette.fg,
    // Flutter 3.19 仍要求 background/onBackground；3.22+ 虽弃用但仍可传。
    background: palette.surface,
    onBackground: palette.fg,
    surface: palette.surface,
    onSurface: palette.fg,
    error: const Color(0xFFCF4274),
    onError: Colors.white,
    outline: palette.outline,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: scheme.brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: Colors.transparent,
    extensions: [palette],
    // Android 14+ 预测性返回 / 全面屏手势；iOS/macOS 用 Cupertino 跟手侧滑
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.linux: ZoomPageTransitionsBuilder(),
        TargetPlatform.windows: ZoomPageTransitionsBuilder(),
      },
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      foregroundColor: palette.fg,
      centerTitle: false,
    ),
    textTheme: TextTheme(
      bodyLarge: TextStyle(color: palette.fg),
      bodyMedium: TextStyle(color: palette.fg),
      bodySmall: TextStyle(color: palette.muted),
      titleLarge: TextStyle(color: palette.fg, fontWeight: FontWeight.w700),
      titleMedium: TextStyle(color: palette.fg, fontWeight: FontWeight.w700),
      titleSmall: TextStyle(color: palette.fg, fontWeight: FontWeight.w600),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: palette.input,
      selectedColor: palette.selected,
      labelStyle: TextStyle(color: palette.fg),
      secondaryLabelStyle: TextStyle(color: palette.fg),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: palette.input,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      hintStyle: TextStyle(color: palette.muted),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: palette.primary,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: palette.bottomNav,
      indicatorColor: palette.selected,
      // MaterialState* 在 3.19 可用；3.22+ 为 WidgetState* 的 typedef。
      labelTextStyle: MaterialStateProperty.resolveWith((states) {
        final selected = states.contains(MaterialState.selected);
        return TextStyle(
          fontSize: 12,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          color: selected ? palette.fg : palette.muted,
        );
      }),
      iconTheme: MaterialStateProperty.resolveWith((states) {
        final selected = states.contains(MaterialState.selected);
        return IconThemeData(color: selected ? Colors.white : palette.muted, size: 24);
      }),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: palette.dialogBg,
      contentTextStyle: TextStyle(color: palette.fg),
      titleTextStyle: TextStyle(color: palette.fg, fontSize: 20, fontWeight: FontWeight.w700),
    ),
  );
}

/// TV 遥控器焦点框。
class TvFocus extends StatefulWidget {
  const TvFocus({
    super.key,
    required this.child,
    this.onPressed,
    this.autofocus = false,
    this.borderRadius = 12,
  });

  final Widget child;
  final VoidCallback? onPressed;
  final bool autofocus;
  final double borderRadius;

  @override
  State<TvFocus> createState() => _TvFocusState();
}

class _TvFocusState extends State<TvFocus> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final focus = KotvPalette.of(context).focus;
    return FocusableActionDetector(
      autofocus: widget.autofocus,
      onShowFocusHighlight: (v) => setState(() => _focused = v),
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
          widget.onPressed?.call();
          return null;
        }),
      },
      // opaque：透明边框区域也要接到点击（手机顶栏胶囊常见点偏失效）
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.borderRadius),
            border: Border.all(
              color: _focused ? focus : Colors.transparent,
              width: 3,
            ),
            boxShadow: _focused
                ? [
                    BoxShadow(
                      color: focus.withOpacity(0.35),
                      blurRadius: 12,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

/// 播放器快捷键（方向键/确认/返回）。
Map<ShortcutActivator, Intent> playerShortcuts = {
  const SingleActivator(LogicalKeyboardKey.select): const ActivateIntent(),
  const SingleActivator(LogicalKeyboardKey.enter): const ActivateIntent(),
  const SingleActivator(LogicalKeyboardKey.space): const ActivateIntent(),
  const SingleActivator(LogicalKeyboardKey.arrowLeft): const _SeekIntent(-10000),
  const SingleActivator(LogicalKeyboardKey.arrowRight): const _SeekIntent(10000),
  const SingleActivator(LogicalKeyboardKey.mediaPlayPause): const ActivateIntent(),
  const SingleActivator(LogicalKeyboardKey.goBack): const DismissIntent(),
  const SingleActivator(LogicalKeyboardKey.escape): const DismissIntent(),
};

class _SeekIntent extends Intent {
  const _SeekIntent(this.deltaMs);
  final int deltaMs;
}

class SeekIntent extends _SeekIntent {
  const SeekIntent(super.deltaMs);
}
