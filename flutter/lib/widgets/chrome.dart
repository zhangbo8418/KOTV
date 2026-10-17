import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../player/kotv_platform.dart';
import '../providers.dart';
import '../theme/layout_scale.dart';
import '../theme/kotv_palette.dart';
import '../theme/kotv_theme.dart';
import '../util/kotv_wallpaper_cache.dart';
import 'h_scroll.dart';
import 'kotv_network_image.dart';
import 'marquee_text.dart';

/// Legacy 背景：按 settings.backdrop（wallMode）切换渐变/壁纸/内置主题。
class AppBackdrop extends ConsumerStatefulWidget {
  const AppBackdrop({
    super.key,
    required this.child,
    this.periodicSettingsRefresh = true,
  });
  final Widget child;

  /// 壳层为 true；详情等嵌套层为 false，避免叠多个 30min 定时器。
  final bool periodicSettingsRefresh;

  @override
  ConsumerState<AppBackdrop> createState() => _AppBackdropState();
}

class _AppBackdropState extends ConsumerState<AppBackdrop> {
  Timer? _wallTimer;
  String _stickyWallUrl = '';
  int _persistGen = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_restoreDiskWall());
    if (!widget.periodicSettingsRefresh) return;
    // 配置壁纸（如每日 bing）定时刷新：先保持 sticky，再换图，避免先 blank。
    _wallTimer = Timer.periodic(const Duration(minutes: 30), (_) {
      if (!mounted) return;
      ref.invalidate(settingsProvider);
    });
  }

  Future<void> _restoreDiskWall() async {
    final hit = await kotvLoadWallpaperDisk();
    if (!mounted || hit == null) return;
    setState(() => _stickyWallUrl = hit.url);
    ref.read(stickyWallUrlProvider.notifier).state = hit.url;
  }

  void _stickWall(String url) {
    final u = url.trim();
    if (u.isEmpty) return;
    if (u == _stickyWallUrl && ref.read(stickyWallUrlProvider) == u) {
      unawaited(kotvPersistWallpaper(u));
      return;
    }
    setState(() => _stickyWallUrl = u);
    ref.read(stickyWallUrlProvider.notifier).state = u;
    final gen = ++_persistGen;
    unawaited(() async {
      await kotvPersistWallpaper(u);
      if (!mounted || gen != _persistGen) return;
      // 落盘后触一次 rebuild，FileImage 可立刻顶上。
      setState(() {});
    }());
  }

  void _clearStickyWall() {
    if (_stickyWallUrl.isEmpty && ref.read(stickyWallUrlProvider).isEmpty) return;
    setState(() => _stickyWallUrl = '');
    ref.read(stickyWallUrlProvider.notifier).state = '';
    unawaited(kotvClearWallpaperDisk());
  }

  @override
  void dispose() {
    _wallTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bd = ref.watch(backdropProvider);
    // 换源清 ImageCache 后递增，强制壁纸层按磁盘/网络重挂。
    ref.watch(wallRepaintProvider);
    final p = ref.watch(kotvPaletteProvider);
    final settingsReady = ref.watch(settingsProvider.select((s) => s.hasValue));
    // settings 未就绪时，回落 config.wallpaper，避免首屏空背景。
    // select 只盯 wallpaper 串：其它 config 字段刷新不重建壁纸层。
    final cfgWall = ref.watch(configProvider.select(
          (async) => async.maybeWhen(
            data: (c) => '${c['wallpaper'] ?? ''}'.trim(),
            orElse: () => '',
          ),
        ));
    final mode = '${bd['mode'] ?? ''}'.trim();
    var image = '${bd['image'] ?? ''}'.trim();
    if (image.isEmpty && (mode.isEmpty || mode == 'config')) {
      image = cfgWall;
    }

    final intentionalNoWall =
        settingsReady && (mode == 'gradient' || mode.startsWith('builtin'));
    if (intentionalNoWall) {
      if (_stickyWallUrl.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _clearStickyWall();
        });
      }
      image = '';
    } else if (image.isNotEmpty) {
      if (image != _stickyWallUrl) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _stickWall(image);
        });
      }
    } else if (_stickyWallUrl.isNotEmpty) {
      // loading / 短暂空串：继续显示上一张。
      image = _stickyWallUrl;
    }

    final hasWall = image.startsWith('http://') || image.startsWith('https://');
    final disk = hasWall ? kotvWallpaperDiskImage(image) : null;
    // 渐变/光晕/压色跟 effectiveLight 走，跟随系统时才会切浅色
    final gradStart = p.gradStart;
    final gradEnd = p.gradEnd;
    final wallTint = p.wallTint;
    final glowTop = p.glowTop;
    final glowBot = p.glowBottom;
    final glowMid = p.glowMid;

    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [gradStart, gradEnd],
            ),
          ),
        ),
        if (hasWall)
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final dpr = MediaQuery.devicePixelRatioOf(context);
                final w = (constraints.maxWidth * dpr).round().clamp(1, 1920);
                // Windows 解码会占着壁纸文件，替换文件时画面会空掉。改成读进内存再画。
                if (kotvIsWindows()) {
                  return _WinWallImage(url: image, decodeWidth: w);
                }
                // 磁盘命中优先：清 ImageCache 后立刻有图，不等网络。
                if (disk != null) {
                  return Image(
                    image: ResizeImage(disk, width: w),
                    fit: BoxFit.cover,
                    filterQuality: FilterQuality.medium,
                    gaplessPlayback: true,
                    errorBuilder: (_, __, ___) => KotvNetworkImage(
                      image,
                      fit: BoxFit.cover,
                      filterQuality: FilterQuality.medium,
                      cacheWidth: w,
                      gaplessPlayback: true,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  );
                }
                return KotvNetworkImage(
                  image,
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.medium,
                  cacheWidth: w,
                  gaplessPlayback: true,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                );
              },
            ),
          ),
        if (hasWall) Positioned.fill(child: ColoredBox(color: wallTint)),
        Positioned(right: -80, top: -120, child: _Glow(glowTop, 420)),
        Positioned(left: -100, bottom: -60, child: _Glow(glowBot, 360)),
        Positioned(right: 80, bottom: 80, child: _Glow(glowMid, 220)),
        widget.child,
      ],
    );
  }
}

/// Windows 壁纸：字节留在内存里画。新图没到之前继续显示上一张。
class _WinWallImage extends StatefulWidget {
  const _WinWallImage({required this.url, required this.decodeWidth});

  final String url;
  final int decodeWidth;

  @override
  State<_WinWallImage> createState() => _WinWallImageState();
}

class _WinWallImageState extends State<_WinWallImage> {
  Uint8List? _bytes;
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load(widget.url));
  }

  @override
  void didUpdateWidget(covariant _WinWallImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) unawaited(_load(widget.url));
  }

  Future<void> _load(String url) async {
    final gen = ++_gen;
    var bytes = await kotvReadWallpaperBytes(url);
    if (bytes == null) {
      await kotvPersistWallpaper(url);
      bytes = await kotvReadWallpaperBytes(url);
    }
    if (!mounted || gen != _gen || bytes == null) return;
    setState(() => _bytes = bytes);
  }

  @override
  Widget build(BuildContext context) {
    final net = KotvNetworkImage(
      widget.url,
      fit: BoxFit.cover,
      filterQuality: FilterQuality.medium,
      cacheWidth: widget.decodeWidth,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
    );
    final bytes = _bytes;
    if (bytes == null) return net;
    // 内存图还没解出来时底下仍是网络图，避免换文件或重解码时闪空。
    return Stack(
      fit: StackFit.expand,
      children: [
        net,
        Image.memory(
          bytes,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.medium,
          gaplessPlayback: true,
          cacheWidth: widget.decodeWidth,
          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
        ),
      ],
    );
  }
}

class _Glow extends StatelessWidget {
  const _Glow(this.color, this.size);
  final Color color;
  final double size;
  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: Container(width: size, height: size, decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
      );
}

/// 导航胶囊：选中粉底 #C73C62（newTVNavPill）。
class NavPill extends StatelessWidget {
  const NavPill({
    super.key,
    required this.label,
    required this.onTap,
    this.selected = false,
    this.autofocus = false,
    this.onFocusChange,
    this.scrollIntoView = false,
    this.trailingIcon,
  });

  final String label;
  final VoidCallback onTap;
  final bool selected;
  final bool autofocus;
  final ValueChanged<bool>? onFocusChange;
  final bool scrollIntoView;
  /// 分类有筛选时旁挂漏斗；展开用划掉态。
  final IconData? trailingIcon;

  @override
  Widget build(BuildContext context) {
    final p = KotvPalette.of(context);
    final compact = KotvLayout.isCompact(context);
    final grow = LayoutScale.growAboveDesign(LayoutScale.of(context));
    final h = (compact ? 32.0 : 36.0) * grow;
    final fs = compact ? 14.0 : 16.0;
    final r = (compact ? 12.0 : 14.0) * grow;
    final px = (compact ? 10.0 : 12.0) * grow;
    final fg = selected ? Colors.white : p.fg;
    return TvFocus(
      autofocus: autofocus,
      onPressed: onTap,
      onFocusChange: onFocusChange,
      scrollIntoView: scrollIntoView,
      borderRadius: r,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          canRequestFocus: false,
          borderRadius: BorderRadius.circular(r),
          child: Container(
            height: h,
            padding: EdgeInsets.symmetric(horizontal: px),
            decoration: BoxDecoration(
              color: selected ? p.selected : Colors.transparent,
              borderRadius: BorderRadius.circular(r),
              border: selected ? Border.all(color: p.primary.withOpacity(0.85)) : null,
            ),
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: fg,
                      fontSize: fs,
                      fontWeight: FontWeight.w700,
                      height: 1.1,
                    ),
                  ),
                ),
                if (trailingIcon != null) ...[
                  SizedBox(width: 4 * grow),
                  Icon(trailingIcon, size: (compact ? 14 : 16) * grow, color: fg),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 深色操作 pill（library / 筛选 / 设置）。
class AppPill extends StatelessWidget {
  const AppPill({
    super.key,
    required this.label,
    required this.onTap,
    this.onLongPress,
    this.selected = false,
    this.width,
    this.maxWidth,
    this.height = 40,
    this.fontSize = 15,
    this.autofocus = false,
    this.focusNode,
    this.suffix,
    this.marqueeWhenSelected = false,
  });

  final String label;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool selected;
  final double? width;
  /// 内容自适应宽度时的上限（站名胶囊用）；与 [width] 互斥优先 [width]。
  final double? maxWidth;
  final double height;
  final double fontSize;
  final bool autofocus;
  final FocusNode? focusNode;
  /// 固定显示在文案后的标记（如「（当前）」），不参与省略，避免长 URL 把标记裁掉。
  final String? suffix;
  /// 选中时对过长 label 跑马灯（直播分组等）。
  final bool marqueeWhenSelected;

  @override
  Widget build(BuildContext context) {
    // 文字可能保持 1.0，控件尺寸不能再按更小的 design scale 缩，否则字撑破胶囊
    final s = LayoutScale.layoutOf(context);
    final p = KotvPalette.of(context);
    final bg = selected ? p.selected : p.pillBg;
    final border = selected ? p.primary.withOpacity(0.9) : p.pillBorder;
    final h = height * s;
    final w = width == null ? null : width! * s;
    final maxW = maxWidth == null ? null : maxWidth! * s;
    final style = TextStyle(
      color: selected ? Colors.white : p.fg,
      fontSize: fontSize,
      fontWeight: FontWeight.w700,
      height: 1.2,
      fontFamilyFallback: kotvFontFallbacks(),
    );
    final hasSuffix = suffix != null && suffix!.isNotEmpty;
    final labelText = marqueeWhenSelected
        ? KotvMarqueeText(
            label,
            style: style,
            active: selected,
            textAlign: hasSuffix ? TextAlign.left : TextAlign.center,
          )
        : Text(
            label,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            textAlign: hasSuffix ? TextAlign.left : TextAlign.center,
            style: style,
          );
    // 有 suffix 时拉满可用宽度，保证「（当前）」不被长 URL 挤掉。
    final effectiveWidth = w ?? (hasSuffix || marqueeWhenSelected ? double.infinity : null);
    final content = hasSuffix
        ? Row(
            children: [
              Expanded(child: labelText),
              Text(suffix!, maxLines: 1, softWrap: false, style: style),
            ],
          )
        : labelText;
    return TvFocus(
      autofocus: autofocus,
      focusNode: focusNode,
      onPressed: onTap,
      borderRadius: 8 * s,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          canRequestFocus: false,
          borderRadius: BorderRadius.circular(8 * s),
          child: Container(
            width: effectiveWidth,
            height: h,
            constraints: effectiveWidth == null && maxW != null ? BoxConstraints(maxWidth: maxW) : null,
            padding: EdgeInsets.symmetric(horizontal: width == null ? 14 * s : 6 * s),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(8 * s),
              border: Border.all(color: border),
            ),
            // 固定高度内垂直居中；自适应宽度时 widthFactor=1 按文字收缩
            child: Align(
              alignment: Alignment.center,
              widthFactor: effectiveWidth == null ? 1 : null,
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}

/// 彩色功能卡：newTVFeatureCard（纯色半透明底 + 描边，非渐变）。
class FeatureCard extends StatelessWidget {
  const FeatureCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.start,
    required this.end,
    required this.onTap,
    this.icon = Icons.star,
    this.height = 124,
  });

  final String title;
  final String subtitle;
  final Color start;
  final Color end;
  final VoidCallback onTap;
  final IconData icon;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final s = LayoutScale.layoutOf(context);
    final grow = LayoutScale.growAboveDesign(s);
    final radius = 14 * s;
    return TvFocus(
      onPressed: onTap,
      borderRadius: radius,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          canRequestFocus: false,
          borderRadius: BorderRadius.circular(radius),
          child: SizedBox(
            height: height,
            width: double.infinity,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: start,
                borderRadius: BorderRadius.circular(radius),
                border: Border.all(color: end.withAlpha(0xA0), width: 1),
              ),
              // 按实际宽高自适应：窄卡用 FittedBox 保证整词可见，矮卡缩字号
              child: LayoutBuilder(
                builder: (context, c) {
                  final h = c.maxHeight;
                  final w = c.maxWidth;
                  final tight = h < 100;
                  final tiny = h < 72;
                  final narrow = w < 168;
                  final padX = (narrow ? 10.0 : (tiny ? 10.0 : (tight ? 12.0 : 16.0))) * grow;
                  final padY = (tiny ? 6.0 : (tight ? 8.0 : 10.0)) * grow;
                  final titleFs = tiny ? 14.0 : (tight || narrow ? 16.0 : 18.0);
                  final subFs = tiny ? 11.0 : (tight || narrow ? 12.0 : 13.0);
                  final iconS = (narrow ? 20.0 : (tiny ? 18.0 : (tight ? 24.0 : 30.0))) * grow;
                  final showSub = subtitle.isNotEmpty && h >= 52;
                  final showIcon = w >= 96;
                  return Padding(
                    padding: EdgeInsets.fromLTRB(padX, padY, padX, padY),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  title,
                                  maxLines: 1,
                                  softWrap: false,
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: titleFs,
                                    fontWeight: FontWeight.w700,
                                    height: 1.1,
                                  ),
                                ),
                              ),
                              if (showSub) ...[
                                SizedBox(height: (tiny ? 2 : 3) * grow),
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    subtitle,
                                    maxLines: 1,
                                    softWrap: false,
                                    style: TextStyle(
                                      color: Colors.white.withOpacity(0xD8 / 255),
                                      fontSize: subFs,
                                      height: 1.1,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        if (showIcon) ...[
                          SizedBox(width: (narrow ? 4 : 8) * grow),
                          Icon(icon, size: iconS, color: Colors.white.withOpacity(0.62)),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key, this.subtitle = ''});
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final p = KotvPalette.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          title,
          textScaler: TextScaler.noScaling,
          style: TextStyle(
            color: p.fg,
            fontSize: scaler.scale(24),
            fontWeight: FontWeight.w700,
          ),
        ),
        if (subtitle.isNotEmpty) ...[
          SizedBox(width: scaler.scale(12)),
          Padding(
            padding: EdgeInsets.only(bottom: scaler.scale(2)),
            child: Text(
              subtitle,
              textScaler: TextScaler.noScaling,
              style: TextStyle(color: p.muted, fontSize: scaler.scale(14)),
            ),
          ),
        ],
      ],
    );
  }
}

/// 详情选集芯片。未选中用胶囊底，选中用强调色。
class EpisodeChip extends StatelessWidget {
  const EpisodeChip({
    super.key,
    required this.label,
    required this.onTap,
    this.selected = false,
    this.autofocus = false,
    this.height = 40,
    this.fontSize = 14,
  });

  final String label;
  final VoidCallback onTap;
  final bool selected;
  final bool autofocus;
  final double height;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final p = KotvPalette.of(context);
    final bg = selected ? p.selected : p.pillBg;
    return TvFocus(
      autofocus: autofocus,
      onPressed: onTap,
      borderRadius: 8,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          canRequestFocus: false,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            height: height,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: selected ? Colors.white : p.fg,
                fontSize: fontSize,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 状态栏 52px。
class TopStatusBar extends StatefulWidget {
  const TopStatusBar({
    super.key,
    required this.siteName,
    required this.onRepo,
    required this.onSite,
    required this.onSettings,
    required this.onNews,
  });

  final String siteName;
  final VoidCallback onRepo;
  final VoidCallback onSite;
  final VoidCallback onSettings;
  final VoidCallback onNews;

  @override
  State<TopStatusBar> createState() => _TopStatusBarState();
}

class _TopStatusBarState extends State<TopStatusBar> {
  late String _clock;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _clock = _fmt(DateTime.now());
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _clock = _fmt(DateTime.now()));
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  static String _fmt(DateTime n) {
    const days = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    String p2(int v) => v.toString().padLeft(2, '0');
    return '${p2(n.month)}月${p2(n.day)}日 ${days[n.weekday - 1]} ${p2(n.hour)}:${p2(n.minute)}:${p2(n.second)}';
  }

  @override
  Widget build(BuildContext context) {
    final s = LayoutScale.layoutOf(context);
    final p = KotvPalette.of(context);
    final compact = KotvLayout.isCompact(context);
    final bottomNav = KotvLayout.useBottomNav(context);
    final landscape = KotvLayout.isLandscapeCompact(context);
    final grow = LayoutScale.growAboveDesign(s);
    final h = (compact ? 40.0 : (landscape ? 36.0 : 52.0)) * grow;
    final padH = compact ? 10.0 : (landscape ? 14.0 : 24.0 * s);
    return Container(
      height: h,
      color: p.statusBar,
      padding: EdgeInsets.symmetric(horizontal: padH),
      child: LayoutBuilder(
        builder: (context, c) {
          final w = c.maxWidth;
          final showNews = !compact && w >= 780;
          final showClock = !compact && !landscape && w >= 980;
          // 右侧整组右对齐：时钟贴站名，不再和 Spacer/Flexible 对半分把时间挤到中间
          return Row(
            children: [
              AppPill(
                label: compact ? '多仓' : '多仓切换',
                height: compact || landscape ? 28 : 36,
                fontSize: compact || landscape ? 12 : 15,
                onTap: widget.onRepo,
              ),
              if (showNews) ...[
                SizedBox(width: 8 * s),
                _NewsPill(onTap: widget.onNews),
              ],
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (showClock) ...[
                      Text(
                        _clock,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: p.fg, fontSize: 15, fontWeight: FontWeight.w700, height: 1.2),
                      ),
                      SizedBox(width: 10 * grow),
                    ],
                    // 按文字宽度自适应；loose 避免拉满剩余空间，超长时再省略
                    Flexible(
                      fit: FlexFit.loose,
                      child: AppPill(
                        label: widget.siteName,
                        height: compact || landscape ? 28 : 36,
                        fontSize: compact || landscape ? 12 : 15,
                        onTap: widget.onSite,
                      ),
                    ),
                    if (!bottomNav) ...[
                      SizedBox(width: (landscape ? 6 : 8) * grow),
                      TvFocus(
                        onPressed: widget.onSettings,
                        child: Material(
                          color: p.pillBg,
                          shape: const CircleBorder(),
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: widget.onSettings,
                            canRequestFocus: false,
                            child: SizedBox(
                              width: (landscape ? 28 : 36) * grow,
                              height: (landscape ? 28 : 36) * grow,
                              child: Icon(Icons.settings,
                                  color: p.fg, size: (landscape ? 16 : 20) * grow),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _NewsPill extends StatelessWidget {
  const _NewsPill({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = LayoutScale.layoutOf(context);
    final grow = LayoutScale.growAboveDesign(s);
    final p = KotvPalette.of(context);
    final radius = 16 * grow;
    return TvFocus(
      onPressed: onTap,
      borderRadius: radius,
      child: InkWell(
        onTap: onTap,
        canRequestFocus: false,
        borderRadius: BorderRadius.circular(radius),
        // 按文字固有宽度收缩，避免固定宽度在字不缩时把内容挤出。
        child: Container(
          height: 32 * grow,
          decoration: BoxDecoration(
              color: p.pillBg, borderRadius: BorderRadius.circular(radius)),
          padding: EdgeInsets.symmetric(horizontal: 12 * grow),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('●', style: TextStyle(color: p.focus, fontSize: 11)),
              SizedBox(width: 6 * grow),
              Text('最新消息', style: TextStyle(color: p.fg, fontSize: 15, fontWeight: FontWeight.w700, height: 1.2)),
            ],
          ),
        ),
      ),
    );
  }
}

class LibraryTopBar extends StatelessWidget {
  const LibraryTopBar({
    super.key,
    required this.onBack,
    required this.onSearch,
    required this.onProfile,
    required this.onNews,
    this.trailing,
    this.title,
  });

  final VoidCallback onBack;
  final VoidCallback onSearch;
  final VoidCallback onProfile;
  final VoidCallback onNews;
  final Widget? trailing;
  final String? title;

  @override
  Widget build(BuildContext context) {
    final compact = KotvLayout.isCompact(context);
    final bottomNav = KotvLayout.useBottomNav(context);
    final land = KotvLayout.isLandscapeCompact(context);
    final pad = EdgeInsets.fromLTRB(
      land ? 16 : (compact ? 12 : 50),
      land ? 6 : 10,
      land ? 16 : (compact ? 12 : 28),
      land ? 6 : 10,
    );
    final pillH = land ? 30.0 : (compact ? 36.0 : 40.0);
    final pillW = land ? 72.0 : (compact ? 88.0 : 104.0);
    final pillFs = land ? 12.0 : 15.0;
    // 竖屏底栏已有搜索/我的：顶栏只留返回（+可选标题/操作）
    if (bottomNav) {
      final backW = 72.0;
      final backH = land ? 30.0 : 32.0;
      final backFs = land ? 12.0 : 13.0;
      return Padding(
        padding: pad,
        child: Row(
          children: [
            AppPill(label: '返回', width: backW, height: backH, fontSize: backFs, onTap: onBack),
            // 有 trailing 时优先保证操作按钮可缩，标题可省略
            if (title != null && title!.isNotEmpty) ...[
              SizedBox(width: land ? 6 : 8),
              Flexible(
                flex: trailing != null ? 1 : 2,
                child: KotvMarqueeText(
                  title!,
                  active: true,
                  style: TextStyle(
                    color: KotvPalette.of(context).fg,
                    fontSize: land ? 14 : 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ] else if (trailing == null)
              const Spacer(),
            if (trailing != null) ...[
              SizedBox(width: land ? 6 : 8),
              Flexible(
                flex: 3,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: trailing!,
                  ),
                ),
              ),
            ],
          ],
        ),
      );
    }
    return Padding(
      padding: pad,
      child: Row(
        children: [
          AppPill(label: '返回', width: pillW, height: pillH, fontSize: pillFs, onTap: onBack),
          SizedBox(width: land ? 6 : 10),
          AppPill(label: '搜索', width: pillW, height: pillH, fontSize: pillFs, onTap: onSearch),
          SizedBox(width: land ? 6 : 10),
          AppPill(label: '我的', width: pillW, height: pillH, fontSize: pillFs, onTap: onProfile),
          if (!compact && !land) ...[
            const SizedBox(width: 10),
            _NewsPill(onTap: onNews),
          ],
          const Spacer(),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class CategoryNavBar extends StatefulWidget {
  const CategoryNavBar({
    super.key,
    required this.homeLabel,
    required this.onHome,
    required this.homeSelected,
    required this.categories,
    required this.selectedTid,
    required this.onCategory,
    required this.onLive,
    this.filtersExpanded = false,
    this.onToggleFilter,
  });

  final String homeLabel;
  final VoidCallback onHome;
  final bool homeSelected;
  final List<({String id, String name, bool hasFilters})> categories;
  final String? selectedTid;
  final void Function(String tid) onCategory;
  /// 再点已选中分类标题时展开/收起筛选。
  final VoidCallback? onToggleFilter;
  final bool filtersExpanded;
  final VoidCallback onLive;

  @override
  State<CategoryNavBar> createState() => _CategoryNavBarState();
}

class _CategoryNavBarState extends State<CategoryNavBar> {
  Timer? _arm;
  String? _pending;

  @override
  void dispose() {
    _arm?.cancel();
    super.dispose();
  }

  /// 焦点落到分类上约 100ms 后切换。滑过时焦点离开就取消，避免连打请求。
  void _onPillFocus(String token, bool focused) {
    if (focused) {
      _arm?.cancel();
      _pending = token;
      _arm = Timer(const Duration(milliseconds: 100), () {
        if (!mounted || _pending != token) return;
        if (token == 'home') {
          if (!widget.homeSelected) widget.onHome();
          return;
        }
        final tid = token.startsWith('cat:') ? token.substring(4) : token;
        if (tid.isEmpty || tid == widget.selectedTid) return;
        widget.onCategory(tid);
      });
      return;
    }
    if (_pending == token) {
      _arm?.cancel();
      _pending = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = LayoutScale.of(context);
    final p = KotvPalette.of(context);
    final compact = KotvLayout.isCompact(context);
    final bottomNav = KotvLayout.useBottomNav(context);
    final selectedIndex = widget.selectedTid == null
        ? -1
        : widget.categories.indexWhere((c) => c.id == widget.selectedTid);
    // 固定高度匹配 NavPill(36)，避免 scale 把栏压矮后胶囊溢出。
    // 按声明顺序走焦点，避免横向列表按几何距离把焦点跳到左边或右边那一项。
    final grow = LayoutScale.growAboveDesign(s);
    return Container(
      height: (compact ? 40.0 : 48.0) * grow,
      color: p.catBar,
      padding: EdgeInsets.symmetric(
          horizontal: compact ? 10.0 : 24.0 * s, vertical: 6 * grow),
      child: FocusTraversalGroup(
        policy: OrderedTraversalPolicy(),
        child: Row(
          children: [
            FocusTraversalOrder(
              order: const NumericFocusOrder(0),
              child: NavPill(
                key: const ValueKey('nav-home'),
                label: widget.homeLabel,
                selected: widget.homeSelected,
                scrollIntoView: true,
                onFocusChange: (v) => _onPillFocus('home', v),
                onTap: widget.onHome,
              ),
            ),
            SizedBox(width: 8 * s),
            Expanded(
              child: HScrollList(
                scrollToIndex: selectedIndex >= 0 ? selectedIndex : null,
                itemCount: widget.categories.length,
                separatorBuilder: (_, __) => SizedBox(width: 8 * s),
                itemBuilder: (_, i) {
                  final c = widget.categories[i];
                  final selected = widget.selectedTid == c.id;
                  IconData? filterIcon;
                  if (c.hasFilters) {
                    filterIcon = (selected && widget.filtersExpanded)
                        ? Icons.filter_alt_off
                        : Icons.filter_alt;
                  }
                  return FocusTraversalOrder(
                    order: NumericFocusOrder(i + 1),
                    child: NavPill(
                      key: ValueKey('nav-cat-${c.id}'),
                      label: c.name,
                      selected: selected,
                      scrollIntoView: true,
                      trailingIcon: filterIcon,
                      onFocusChange: (v) => _onPillFocus('cat:${c.id}', v),
                      onTap: () {
                        if (selected) {
                          if (c.hasFilters) widget.onToggleFilter?.call();
                          return;
                        }
                        widget.onCategory(c.id);
                      },
                    ),
                  );
                },
              ),
            ),
            if (!bottomNav) ...[
              SizedBox(width: 8 * s),
              FocusTraversalOrder(
                order: NumericFocusOrder(widget.categories.length + 1),
                child: NavPill(
                  key: const ValueKey('nav-live'),
                  label: '直播',
                  onTap: widget.onLive,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 弹窗文字按钮。遥控器落点画焦点环；内层不再单独进焦点遍历。
class KotvFocusAction extends StatelessWidget {
  const KotvFocusAction({
    super.key,
    required this.label,
    required this.onPressed,
    this.color,
    this.fontWeight = FontWeight.w600,
    this.fontSize,
    this.underline = false,
    this.autofocus = false,
    this.filled = false,
    this.fillColor,
  });

  final String label;
  final VoidCallback onPressed;
  final Color? color;
  final FontWeight fontWeight;
  final double? fontSize;
  final bool underline;
  final bool autofocus;
  final bool filled;
  final Color? fillColor;

  @override
  Widget build(BuildContext context) {
    final p = KotvPalette.of(context);
    final fg = color ?? (filled ? Colors.white : p.fg);
    final labelWidget = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Text(
        label,
        style: TextStyle(
          color: fg,
          fontWeight: fontWeight,
          fontSize: fontSize,
          decoration: underline ? TextDecoration.underline : null,
        ),
      ),
    );
    return TvFocus(
      autofocus: autofocus,
      onPressed: onPressed,
      borderRadius: 8,
      child: filled
          ? DecoratedBox(
              decoration: BoxDecoration(
                color: fillColor ?? p.primary,
                borderRadius: BorderRadius.circular(8),
              ),
              child: labelWidget,
            )
          : labelWidget,
    );
  }
}

void showAppNews(BuildContext context, String message) {
  final p = KotvPalette.of(context);
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: p.dialogBg,
      title: Text('提示', style: TextStyle(color: p.fg)),
      content: Text(message, style: TextStyle(color: p.muted)),
      actions: [
        KotvFocusAction(label: '好的', color: p.primary, autofocus: true, onPressed: () => Navigator.pop(ctx)),
      ],
    ),
  );
}
