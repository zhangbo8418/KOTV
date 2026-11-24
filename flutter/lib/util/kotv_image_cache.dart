import 'package:flutter/widgets.dart';

import '../widgets/kotv_poster_image.dart';

/// 启动时为 Image 路径设字节上限（台标/详情封面等）；列表海报、壳层壁纸自管解码。
void kotvConfigureImageCacheBudget() {
  PaintingBinding.instance.imageCache.maximumSizeBytes = 64 << 20; // 64MB
}

/// 清全局 ImageCache 与海报解码池（壳层壁纸自持解码结果，不受影响）。
Future<void> kotvClearImageMemory() async {
  final cache = PaintingBinding.instance.imageCache;
  cache.clear();
  cache.clearLiveImages();
  kotvClearPosterImageCache();
}
