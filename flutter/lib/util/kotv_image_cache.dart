import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../widgets/kotv_poster_image.dart';

/// 启动时为 Image 路径设字节上限（壁纸/台标/详情封面等）；列表海报自管解码池。
void kotvConfigureImageCacheBudget() {
  PaintingBinding.instance.imageCache.maximumSizeBytes = 64 << 20; // 64MB
}

/// 清全局 ImageCache 与海报解码池，并触发壳层重挂壁纸。
Future<void> kotvClearImageMemory({WidgetRef? ref}) async {
  final cache = PaintingBinding.instance.imageCache;
  cache.clear();
  cache.clearLiveImages();
  kotvClearPosterImageCache();
  if (ref != null) {
    ref.read(wallRepaintProvider.notifier).state++;
  }
}
