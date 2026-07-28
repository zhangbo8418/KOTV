import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../theme/layout_scale.dart';
import '../theme/kotv_palette.dart';
import '../theme/kotv_theme.dart';

/// Legacy TV 背景：按 settings.backdrop（wallMode）切换渐变/壁纸/内置主题。
class AppBackdrop extends ConsumerStatefulWidget {
  const AppBackdrop({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<AppBackdrop> createState() => _AppBackdropState();
}

class _AppBackdropState extends ConsumerState<AppBackdrop> {
  Timer? _wallTimer;

  @override
  void initState() {
    super.initState();
    // 对齐 Legacy：配置壁纸（如每日 bing）定时刷新。
    _wallTimer = Timer.periodic(const Duration(minutes: 30), (_) {
      if (!mounted) return;
      ref.invalidate(settingsProvider);
    });
  }

  @override
  void dispose() {
    _wallTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bd = ref.watch(backdropProvider);
    final p = ref.watch(kotvPaletteProvider);
    // settings 未就绪时，回落 config.wallpaper，避免首屏空背景。
    final cfgWall = ref.watch(configProvider).maybeWhen(
          data: (c) => '${c['wallpaper'] ?? ''}'.trim(),
          orElse: () => '',
        );
    final mode = '${bd['mode'] ?? ''}'.trim();
    var image = '${bd['image'] ?? ''}'.trim();
    if (image.isEmpty && (mode.isEmpty || mode == 'config')) {
      image = cfgWall;
    }
    final hasWall = image.startsWith('http://') || image.startsWith('https://');
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
                return Image.network(
                  image,
                  key: ValueKey('$mode|$image'),
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.medium,
                  // 限制解码尺寸，降低 Win7 上大图解码导致的原生闪退风险
                  cacheWidth: w,
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
  });

  final String label;
  final VoidCallback onTap;
  final bool selected;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final p = KotvPalette.of(context);
    final compact = KotvLayout.isCompact(context);
    final h = compact ? 32.0 : 36.0;
    final fs = compact ? 14.0 : 16.0;
    final r = compact ? 12.0 : 14.0;
    final px = compact ? 10.0 : 12.0;
    return TvFocus(
      autofocus: autofocus,
      onPressed: onTap,
      borderRadius: r,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
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
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: selected ? Colors.white : p.fg,
                fontSize: fs,
                fontWeight: FontWeight.w700,
                height: 1.1,
              ),
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
    this.selected = false,
    this.width,
    this.height = 40,
    this.fontSize = 15,
    this.autofocus = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool selected;
  final double? width;
  final double height;
  final double fontSize;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    // 文字可能保持 1.0，控件尺寸不能再按更小的 design scale 缩，否则字撑破胶囊
    final s = LayoutScale.layoutOf(context);
    final p = KotvPalette.of(context);
    final bg = selected ? p.selected : p.pillBg;
    final border = selected ? p.primary.withOpacity(0.9) : p.pillBorder;
    final h = height * s;
    final w = width == null ? null : width! * s;
    final labelText = Text(
      label,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
      style: TextStyle(
        color: selected ? Colors.white : p.fg,
        fontSize: fontSize,
        fontWeight: FontWeight.w700,
        height: 1.2,
      ),
    );
    return TvFocus(
      autofocus: autofocus,
      onPressed: onTap,
      borderRadius: 8 * s,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8 * s),
          child: Container(
            width: w,
            height: h,
            padding: EdgeInsets.symmetric(horizontal: width == null ? 14 * s : 6 * s),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(8 * s),
              border: Border.all(color: border),
            ),
            child: Align(
              alignment: Alignment.center,
              widthFactor: w == null ? 1 : null,
              child: labelText,
            ),
          ),
        ),
      ),
    );
  }
}

/// 彩色功能卡：对齐 Legacy newTVFeatureCard（纯色半透明底 + 描边，非渐变）。
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
    final radius = 14 * s.clamp(0.75, 1.2);
    return TvFocus(
      onPressed: onTap,
      borderRadius: radius,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
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
                  final padX = narrow ? 10.0 : (tiny ? 10.0 : (tight ? 12.0 : 16.0));
                  final padY = tiny ? 6.0 : (tight ? 8.0 : 10.0);
                  final titleFs = tiny ? 14.0 : (tight || narrow ? 16.0 : 18.0);
                  final subFs = tiny ? 11.0 : (tight || narrow ? 12.0 : 13.0);
                  final iconS = narrow ? 20.0 : (tiny ? 18.0 : (tight ? 24.0 : 30.0));
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
                                SizedBox(height: tiny ? 2 : 3),
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
                          SizedBox(width: narrow ? 4 : 8),
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
    return SizedBox(
      height: 32,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(title, style: TextStyle(color: p.fg, fontSize: 24, fontWeight: FontWeight.w700)),
          if (subtitle.isNotEmpty) ...[
            const SizedBox(width: 12),
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(subtitle, style: TextStyle(color: p.muted, fontSize: 14)),
            ),
          ],
        ],
      ),
    );
  }
}

/// 详情选集芯片：对齐 Legacy newDetailEpisodeChip（半透明紫底 / 选中粉底）。
class EpisodeChip extends StatelessWidget {
  const EpisodeChip({
    super.key,
    required this.label,
    required this.onTap,
    this.selected = false,
    this.autofocus = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool selected;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final bg = selected ? const Color(0xF2C73C62) : const Color(0x9E141038);
    return TvFocus(
      autofocus: autofocus,
      onPressed: onTap,
      borderRadius: 8,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700),
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
    final h = compact ? 40.0 : (landscape ? 44.0 : 52.0);
    final padH = compact ? 10.0 : 24.0 * s;
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
                height: compact ? 32 : 36,
                fontSize: compact ? 13 : 15,
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
                      const SizedBox(width: 10),
                    ],
                    Flexible(
                      child: AppPill(
                        label: widget.siteName,
                        height: compact ? 32 : 36,
                        fontSize: compact ? 13 : 15,
                        onTap: widget.onSite,
                      ),
                    ),
                    if (!bottomNav) ...[
                      const SizedBox(width: 8),
                      TvFocus(
                        onPressed: widget.onSettings,
                        child: Material(
                          color: p.pillBg,
                          shape: const CircleBorder(),
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: widget.onSettings,
                            child: SizedBox(
                              width: 36,
                              height: 36,
                              child: Icon(Icons.settings, color: p.fg, size: 20),
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
    final p = KotvPalette.of(context);
    return TvFocus(
      onPressed: onTap,
      borderRadius: 16 * s,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16 * s),
        // 按文字固有宽度收缩，避免固定 132*s 在「字不缩、壳缩小」时内部 RIGHT OVERFLOW
        child: Container(
          height: 32,
          decoration: BoxDecoration(color: p.input.withOpacity(0.85), borderRadius: BorderRadius.circular(16)),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('●', style: TextStyle(color: p.focus, fontSize: 11)),
              const SizedBox(width: 6),
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
    final pad = EdgeInsets.fromLTRB(compact ? 12 : 50, 10, compact ? 12 : 28, 10);
    // 竖屏底栏已有搜索/我的：顶栏只留返回（+可选标题）
    if (bottomNav) {
      return Padding(
        padding: pad,
        child: Row(
          children: [
            AppPill(label: '返回', width: 88, height: 36, onTap: onBack),
            if (title != null && title!.isNotEmpty) ...[
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700),
                ),
              ),
            ] else
              const Spacer(),
            if (trailing != null) trailing!,
          ],
        ),
      );
    }
    return Padding(
      padding: pad,
      child: Row(
        children: [
          AppPill(label: '返回', width: compact ? 88 : 104, height: compact ? 36 : 40, onTap: onBack),
          const SizedBox(width: 10),
          AppPill(label: '搜索', width: compact ? 88 : 104, height: compact ? 36 : 40, onTap: onSearch),
          const SizedBox(width: 10),
          AppPill(label: '我的', width: compact ? 88 : 104, height: compact ? 36 : 40, onTap: onProfile),
          if (!compact) ...[
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

class CategoryNavBar extends StatelessWidget {
  const CategoryNavBar({
    super.key,
    required this.homeLabel,
    required this.onHome,
    required this.homeSelected,
    required this.categories,
    required this.selectedTid,
    required this.onCategory,
    required this.onLive,
  });

  final String homeLabel;
  final VoidCallback onHome;
  final bool homeSelected;
  final List<({String id, String name})> categories;
  final String? selectedTid;
  final void Function(String tid) onCategory;
  final VoidCallback onLive;

  @override
  Widget build(BuildContext context) {
    final s = LayoutScale.of(context);
    final p = KotvPalette.of(context);
    final compact = KotvLayout.isCompact(context);
    final bottomNav = KotvLayout.useBottomNav(context);
    // 固定高度匹配 NavPill(36)，避免 scale 把栏压矮后胶囊溢出
    return Container(
      height: compact ? 40.0 : 48.0,
      color: p.catBar,
      padding: EdgeInsets.symmetric(horizontal: compact ? 10.0 : 24.0 * s, vertical: 6),
      child: Row(
        children: [
          NavPill(label: homeLabel, selected: homeSelected, onTap: onHome),
          SizedBox(width: 8 * s),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: categories.length,
              separatorBuilder: (_, __) => SizedBox(width: 8 * s),
              itemBuilder: (_, i) {
                final c = categories[i];
                return NavPill(
                  label: c.name,
                  selected: selectedTid == c.id,
                  onTap: () => onCategory(c.id),
                );
              },
            ),
          ),
          // 竖屏底栏已有「直播」
          if (!bottomNav) ...[
            SizedBox(width: 8 * s),
            NavPill(label: '直播', onTap: onLive),
          ],
        ],
      ),
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
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text('好的', style: TextStyle(color: p.primary)))],
    ),
  );
}
