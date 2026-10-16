import 'package:flutter/material.dart';

import '../models/models.dart';
import '../theme/layout_scale.dart';
import '../theme/kotv_palette.dart';
import '../theme/kotv_theme.dart';
import '../vod/grid_style.dart';
import '../vod/list_style.dart';
import 'kotv_network_image.dart';
import 'kotv_poster_image.dart';

/// 海报：图片按比例裁切，标题在图片下面，备注在图片上。
class PosterCard extends StatelessWidget {
  const PosterCard({
    super.key,
    required this.item,
    required this.onTap,
    this.onLongPress,
    this.autofocus = false,
    this.ratio = 0.75,
    this.oval = false,
  });

  final VodItem item;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool autofocus;

  /// 图片宽高比（宽 / 高）。格子高度已按它算好，这里只决定裁切形状。
  final double ratio;
  final bool oval;

  @override
  Widget build(BuildContext context) {
    final s = LayoutScale.of(context);
    final p = KotvPalette.of(context);
    return TvFocus(
      autofocus: autofocus,
      onPressed: onTap,
      onLongPress: onLongPress,
      borderRadius: 10 * s,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10 * s),
          child: LayoutBuilder(
            builder: (context, c) {
              if (!c.hasBoundedHeight ||
                  !c.hasBoundedWidth ||
                  c.maxHeight <= 0 ||
                  c.maxWidth <= 0) {
                return ColoredBox(color: p.posterPh);
              }
              final titleH = kotvPosterTitleDesign * s;
              final designW = kotvPosterDesignBucket(c.maxWidth,
                  max: ratio > 1 ? 640 : 480);
              final letter = () {
                final name = item.name.trim();
                if (name.isEmpty) return '?';
                final it = name.runes.iterator;
                return it.moveNext() ? String.fromCharCode(it.current) : '?';
              }();
              Widget image = ColoredBox(
                color: p.posterPh,
                child: item.pic.isEmpty || !_isHttpPic(item.pic)
                    ? Center(
                        child: item.isFolder
                            ? Icon(Icons.folder_outlined,
                                color: p.fg.withOpacity(0.35), size: 54 * s)
                            : Text(
                                letter,
                                style: TextStyle(
                                  color: p.fg.withOpacity(0.35),
                                  fontSize: 54 * s,
                                  fontWeight: FontWeight.w700,
                                  height: 1.2,
                                ),
                              ),
                      )
                    : KotvPosterNetImage(
                        item.pic.trim(),
                        fit: BoxFit.cover,
                        designWidth: designW,
                        errorBuilder: (_, __, ___) =>
                            ColoredBox(color: p.posterPh),
                      ),
              );
              if (oval) image = ClipOval(child: image);
              return Column(
                children: [
                  Expanded(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        image,
                        if (item.remarks.isNotEmpty)
                          Positioned(
                            left: 5 * s,
                            right: 5 * s,
                            bottom: 4 * s,
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Container(
                                padding: EdgeInsets.symmetric(
                                    horizontal: 5 * s, vertical: 2 * s),
                                decoration: BoxDecoration(
                                  color: p.primary.withOpacity(0.9),
                                  borderRadius: BorderRadius.circular(5 * s),
                                ),
                                child: Text(
                                  item.remarks,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    height: 1.2,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  SizedBox(
                    height: titleH,
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 4 * s),
                      child: Align(
                        alignment: Alignment.center,
                        child: Text(
                          item.name,
                          maxLines: titleH >= 40 ? 2 : 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: p.fg,
                            fontSize: 13 * s,
                            fontWeight: FontWeight.w700,
                            height: 1.15,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  static bool _isHttpPic(String s) => kotvIsPictureUrl(s);
}

bool kotvIsPictureUrl(String s) {
  if (kotvDecodeDataImage(s) != null) return true;
  final u = kotvResolveImageRequest(s).url;
  return u.startsWith('http://') || u.startsWith('https://');
}

/// 横向一行：48 图、名称、备注。没有图时显示名称首字。
class VodListTile extends StatelessWidget {
  const VodListTile({
    super.key,
    required this.item,
    required this.onTap,
    this.onLongPress,
  });

  final VodItem item;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final p = KotvPalette.of(context);
    final pic = item.pic.trim();
    final letter = kotvNameInitial(item.name);
    final thumb = pic.isNotEmpty && kotvIsPictureUrl(pic)
        ? KotvPosterNetImage(
            pic,
            fit: BoxFit.cover,
            designWidth: 48,
            errorBuilder: (_, __, ___) => _ListInitial(letter: letter),
          )
        : _ListInitial(letter: letter);
    return TvFocus(
      onPressed: onTap,
      onLongPress: onLongPress,
      borderRadius: 8,
      child: SizedBox(
        height: 56,
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(width: 48, height: 48, child: thumb),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: p.fg, fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  if (item.remarks.isNotEmpty)
                    Text(
                      item.remarks,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: p.muted, fontSize: 12),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ListInitial extends StatelessWidget {
  const _ListInitial({required this.letter});
  final String letter;

  @override
  Widget build(BuildContext context) {
    final p = KotvPalette.of(context);
    return ColoredBox(
      color: p.posterPh,
      child: Center(
        child: Text(
          letter,
          style:
              TextStyle(color: p.fg, fontSize: 20, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}

/// 海报流：列数按屏幕方向、短边和海报尺寸档计算。列表样式改成横向行。
class PosterFlow extends StatelessWidget {
  const PosterFlow({
    super.key,
    required this.items,
    required this.onOpen,
    this.onLongPress,
    this.padding = const EdgeInsets.fromLTRB(50, 10, 50, 24),
    this.size = 2,
    this.style = const KotvGridStyle(),
  });

  final List<VodItem> items;
  final void Function(VodItem) onOpen;
  final void Function(VodItem)? onLongPress;
  final EdgeInsets padding;
  final int size;
  final KotvGridStyle style;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final pad = KotvLayout.isCompact(context)
            ? const EdgeInsets.fromLTRB(12, 8, 12, 16)
            : padding;
        final inner = c.maxWidth - pad.horizontal;
        final m =
            kotvPosterMetrics(context, extent: inner, style: style, size: size);
        if (style.isList) {
          return ListView.builder(
            padding: pad,
            addAutomaticKeepAlives: false,
            cacheExtent: 800,
            itemCount: items.length,
            itemBuilder: (context, i) {
              final it = items[i];
              return VodListTile(
                item: it,
                onTap: () => onOpen(it),
                onLongPress:
                    onLongPress == null ? null : () => onLongPress!(it),
              );
            },
          );
        }
        return GridView.builder(
          padding: pad,
          addAutomaticKeepAlives: false,
          cacheExtent: 800,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: m.columns,
            mainAxisSpacing: m.gap,
            crossAxisSpacing: m.gap,
            childAspectRatio: m.aspect,
          ),
          itemCount: items.length,
          itemBuilder: (context, i) {
            final it = items[i];
            return PosterCard(
              item: it,
              autofocus: false,
              ratio: style.ratio,
              oval: style.isOval,
              onTap: () => onOpen(it),
              onLongPress: onLongPress == null ? null : () => onLongPress!(it),
            );
          },
        );
      },
    );
  }
}
