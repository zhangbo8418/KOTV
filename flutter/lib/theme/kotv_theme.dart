import '../util/kotv_io.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../player/kotv_platform.dart';
import '../widgets/marquee_text.dart';
import 'kotv_palette.dart';

/// lumen 默认色板（兼容旧引用；新代码优先 [KotvPalette.of]）。
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

/// 字体回退：各平台优先系统字体；内嵌 Noto 仅 Win7 发行包携带。
///
/// Emoji：Win7 包内同时带 [NotoColorEmoji] 与 [NotoEmoji]，但回退链按**运行时的系统版本**区分——
/// Win10/11 只用彩色（Segoe UI Emoji / NotoColorEmoji），绝不把 NotoEmoji 放前面，否则会整页黑白 emoji。
/// 真 Win7 上 COLR 常认字却渲不出，须把 [NotoEmoji]（黑白）放在 [NotoColorEmoji] 前面。
List<String> kotvFontFallbacks() => _kotvFontFallbacks();

List<String> _kotvFontFallbacks() {
  if (kIsWeb) return const [];
  if (Platform.isWindows) {
    if (kotvIsWindows7()) {
      // COLR 在 Win7 常认字却渲不出；黑白 NotoEmoji 必须排在彩色前面，否则会空白。
      return const [
        'Segoe UI',
        'Microsoft YaHei UI',
        'Microsoft YaHei',
        'NotoSansSC',
        'NotoEmoji',
        'NotoColorEmoji',
        'Segoe UI Symbol',
      ];
    }
    return const [
      'Segoe UI',
      'Microsoft YaHei UI',
      'Microsoft YaHei',
      'NotoSansSC',
      'Segoe UI Emoji',
      'NotoColorEmoji',
      'Segoe UI Symbol',
    ];
  }
  if (Platform.isLinux) {
    return const [
      'Noto Sans',
      'DejaVu Sans',
      'Noto Sans CJK SC',
      'Noto Color Emoji',
    ];
  }
  if (Platform.isAndroid) {
    return const ['sans-serif', 'Noto Sans CJK SC', 'Noto Color Emoji'];
  }
  return const ['PingFang SC', 'Hiragino Sans GB', 'Apple Color Emoji'];
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
  final fallbacks = _kotvFontFallbacks();
  // 仅 Win7 内嵌 NotoSansSC；其它平台用系统默认无衬线 + fallback 链。
  final useEmbeddedCJK = !kIsWeb && Platform.isWindows && kotvIsWindows7();
  return ThemeData(
    useMaterial3: true,
    brightness: scheme.brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: Colors.transparent,
    extensions: [palette],
    fontFamily: useEmbeddedCJK ? 'NotoSansSC' : null,
    fontFamilyFallback: fallbacks,
    // Android 14+ 预测性返回 / 全面屏手势；iOS/macOS 用 Cupertino 跟手侧滑
    // Win7（Flutter 3.19）由 adapt-flutter-win7-sdk.sh 将 PredictiveBack 换成 Zoom
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: ZoomPageTransitionsBuilder(),
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
      bodyLarge: TextStyle(color: palette.fg, fontFamilyFallback: fallbacks),
      bodyMedium: TextStyle(color: palette.fg, fontFamilyFallback: fallbacks),
      bodySmall: TextStyle(color: palette.muted, fontFamilyFallback: fallbacks),
      titleLarge: TextStyle(color: palette.fg, fontWeight: FontWeight.w700, fontFamilyFallback: fallbacks),
      titleMedium: TextStyle(color: palette.fg, fontWeight: FontWeight.w700, fontFamilyFallback: fallbacks),
      titleSmall: TextStyle(color: palette.fg, fontWeight: FontWeight.w600, fontFamilyFallback: fallbacks),
      // NavigationBar 默认会用 labelSmall/labelMedium！；缺了就变「Null check operator」。
      labelLarge: TextStyle(color: palette.fg, fontSize: 14, fontWeight: FontWeight.w600, fontFamilyFallback: fallbacks),
      labelMedium: TextStyle(color: palette.fg, fontSize: 12, fontWeight: FontWeight.w600, fontFamilyFallback: fallbacks),
      labelSmall: TextStyle(color: palette.muted, fontSize: 11, fontWeight: FontWeight.w500, fontFamilyFallback: fallbacks),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: palette.input,
      selectedColor: palette.selected,
      labelStyle: TextStyle(color: palette.fg, fontFamilyFallback: fallbacks),
      secondaryLabelStyle: TextStyle(color: palette.fg, fontFamilyFallback: fallbacks),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: palette.input,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: palette.outline.withOpacity(0.35))),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: palette.primary.withOpacity(0.75), width: 1.2)),
      hintStyle: TextStyle(color: palette.muted, fontFamilyFallback: fallbacks),
      labelStyle: TextStyle(color: palette.fg, fontFamilyFallback: fallbacks),
      // 输入文字跟主题前景色，避免浅底白字看不清
      floatingLabelStyle: TextStyle(color: palette.muted, fontFamilyFallback: fallbacks),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: palette.primary,
      selectionColor: palette.primary.withOpacity(0.35),
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
      elevation: 0,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      // MaterialState* 在 3.19 可用；3.22+ 为 WidgetState* 的 typedef。
      labelTextStyle: MaterialStateProperty.resolveWith((states) {
        final selected = states.contains(MaterialState.selected);
        return TextStyle(
          fontSize: 12,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          color: selected ? palette.fg : palette.muted,
          fontFamilyFallback: fallbacks,
        );
      }),
      iconTheme: MaterialStateProperty.resolveWith((states) {
        final selected = states.contains(MaterialState.selected);
        return IconThemeData(color: selected ? Colors.white : palette.muted, size: 24);
      }),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: palette.dialogBg,
      elevation: 0,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      contentTextStyle: TextStyle(color: palette.fg, fontFamilyFallback: fallbacks),
      titleTextStyle: TextStyle(color: palette.fg, fontSize: 20, fontWeight: FontWeight.w700, fontFamilyFallback: fallbacks),
    ),
  );
}

/// 遥控器焦点框。
/// 浅色底上过亮的焦点色向近黑压深，避免淡蓝融进背景。
/// 深色底上过暗的颜色向白色提亮。播控画在画面上时走深色底。
Color kotvFocusRingColor(KotvPalette pal, {bool onDarkSurface = false}) {
  final focus = pal.focus;
  if (pal.light && !onDarkSurface) {
    return focus;
  }
  if (focus.computeLuminance() >= 0.4) return focus;
  return Color.lerp(focus, Colors.white, 0.55) ?? focus;
}

/// 焦点环默认关闭。鼠标、触控、触控板按下关掉；键盘或遥控器按键才打开。
class KotvKeyHighlight {
  KotvKeyHighlight._();

  static final ValueNotifier<bool> active = ValueNotifier<bool>(false);
  static var _installed = false;

  static void install() {
    if (_installed) return;
    _installed = true;
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  static bool _onKey(KeyEvent event) {
    if ((event is KeyDownEvent || event is KeyRepeatEvent) && !active.value) {
      active.value = true;
    }
    return false;
  }

  static void disarm() {
    if (active.value) active.value = false;
  }
}

/// 把框架焦点高亮接到 [KotvKeyHighlight]：未按键时不画环。
mixin KotvKeyHighlightState<T extends StatefulWidget> on State<T> {
  @override
  void initState() {
    super.initState();
    KotvKeyHighlight.active.addListener(_kotvOnKeyHighlight);
  }

  @override
  void dispose() {
    KotvKeyHighlight.active.removeListener(_kotvOnKeyHighlight);
    super.dispose();
  }

  void _kotvOnKeyHighlight() {
    if (mounted) setState(() {});
  }

  bool kotvRing(bool frameworkHighlight) => frameworkHighlight && KotvKeyHighlight.active.value;
}

/// 遥控器焦点环：键盘/遥控亮框，鼠标点击不留下常亮框。
class TvFocus extends StatefulWidget {
  const TvFocus({
    super.key,
    required this.child,
    this.onPressed,
    this.onLongPress,
    this.autofocus = false,
    this.focusNode,
    this.borderRadius = 12,
    this.scrollIntoView = false,
    this.onFocusChange,
  });

  final Widget child;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final bool autofocus;
  /// 外部持有时可 [FocusNode.requestFocus]（全屏亮控件后强制落到播停）。
  final FocusNode? focusNode;
  final double borderRadius;
  /// 获焦时把当前项滚进所属的横向/纵向滚动区域。
  final bool scrollIntoView;
  final ValueChanged<bool>? onFocusChange;

  @override
  State<TvFocus> createState() => _TvFocusState();
}

class _TvFocusState extends State<TvFocus> with KotvKeyHighlightState {
  bool _highlight = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final pal = KotvPalette.of(context);
    final ring = kotvFocusRingColor(pal);
    final fill = pal.light ? 0.16 : 0.22;
    final lightBorderOnly = pal.light;
    return FocusableActionDetector(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onFocusChange: widget.onFocusChange,
      // 只用系统「是否该画焦点」：遥控/键盘会亮，鼠标点击不会留下常亮框。
      onShowFocusHighlight: (v) {
        if (v && widget.scrollIntoView) {
          final ctx = context;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!ctx.mounted) return;
            _jumpNearestScrollableIfClipped(ctx);
          });
        }
        if (_highlight == v) return;
        setState(() => _highlight = v);
      },
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
          widget.onPressed?.call();
          return null;
        }),
      },
      // opaque：透明边框区域也要接到点击（手机顶栏胶囊常见点偏失效）
      child: MouseRegion(
        onEnter: (_) {
          if (_hovered) return;
          setState(() => _hovered = true);
        },
        onExit: (_) {
          if (!_hovered) return;
          setState(() => _hovered = false);
        },
        child: KotvMarqueeHost(
          active: kotvRing(_highlight) || _hovered,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPressed,
            onLongPress: widget.onLongPress,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(widget.borderRadius),
                color: kotvRing(_highlight) && !lightBorderOnly ? ring.withOpacity(fill) : null,
                border: Border.all(
                  color: kotvRing(_highlight) ? ring : Colors.transparent,
                  width: kotvRing(_highlight) ? 3 : 0,
                ),
                boxShadow: kotvRing(_highlight) && !lightBorderOnly
                    ? [
                        BoxShadow(
                          color: ring.withOpacity(0.55),
                          blurRadius: 14,
                          spreadRadius: 1,
                        ),
                      ]
                    : null,
              ),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

/// 最近一层滚动区里已经完整露出就不动；被裁切时立刻跳到刚好露出。
/// 不带动外层滚动，也不做一段滚动动画。
void _jumpNearestScrollableIfClipped(BuildContext context) {
  final object = context.findRenderObject();
  if (object == null || !object.attached) return;
  final viewport = RenderAbstractViewport.maybeOf(object);
  final scrollable = Scrollable.maybeOf(context);
  if (viewport == null || scrollable == null) return;
  final position = scrollable.position;
  if (!position.hasContentDimensions) return;
  try {
    final revealed = RevealedOffset.clampOffset(
      leadingEdgeOffset: viewport.getOffsetToReveal(object, 0.0, axis: position.axis),
      trailingEdgeOffset: viewport.getOffsetToReveal(object, 1.0, axis: position.axis),
      currentOffset: position.pixels,
    );
    if (revealed == null) return;
    final target = revealed.offset.clamp(position.minScrollExtent, position.maxScrollExtent).toDouble();
    if (target == position.pixels) return;
    position.jumpTo(target);
  } catch (_) {}
}
