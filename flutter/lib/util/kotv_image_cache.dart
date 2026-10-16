import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../player/kotv_platform.dart';
import '../providers.dart';
import 'kotv_wallpaper_cache.dart';
import '../widgets/kotv_network_image.dart';
import '../widgets/kotv_poster_image.dart';

/// 启动时为 Image 路径设字节上限（壁纸/台标/详情封面等）；列表海报自管解码池。
void kotvConfigureImageCacheBudget() {
  PaintingBinding.instance.imageCache.maximumSizeBytes = 64 << 20; // 64MB
}

/// 清全局 ImageCache 与海报解码池；立刻按粘住的壁纸预热并触发壳层重挂。
Future<void> kotvClearImageMemory({
  BuildContext? context,
  WidgetRef? ref,
  String? wallUrl,
}) async {
  final cache = PaintingBinding.instance.imageCache;
  cache.clear();
  cache.clearLiveImages();
  kotvClearPosterImageCache();

  final url = (wallUrl ?? ref?.read(stickyWallUrlProvider) ?? '').trim();
  if (ref != null) {
    ref.read(wallRepaintProvider.notifier).state++;
  }

  if (context == null || !context.mounted || url.isEmpty) return;

  if (kotvIsWindows()) {
    final bytes = await kotvReadWallpaperBytes(url);
    if (!context.mounted || bytes == null) return;
    try {
      await precacheImage(MemoryImage(bytes), context);
    } catch (_) {}
    return;
  }
  final disk = kotvWallpaperDiskImage(url);
  if (disk != null) {
    try {
      await precacheImage(disk, context);
    } catch (_) {}
  }
  if (!context.mounted) return;
  final net = kotvResolvedImageProvider(url);
  if (net == null) return;
  try {
    await precacheImage(net, context);
  } catch (_) {}
}
