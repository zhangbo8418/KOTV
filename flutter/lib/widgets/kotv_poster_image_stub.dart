import 'package:flutter/material.dart';

import 'kotv_network_image.dart';

/// Web：无独立解码池，清缓存由 ImageCache 承担。
void kotvClearPosterImageCache() {}

/// 与 IO 实现同名：逻辑尺寸量化桶（Web 仅给 ResizeImage 用）。
double kotvPosterDesignBucket(double logical, {double max = 214}) {
  if (!(logical > 0)) return max;
  final stepped = ((logical + 15) ~/ 16) * 16;
  return stepped.clamp(48, max).toDouble();
}

/// Web：无 dart:io abort，回落网络图 + 固定解码桶。
class KotvPosterNetImage extends StatelessWidget {
  const KotvPosterNetImage(
    this.pic, {
    super.key,
    this.fit = BoxFit.cover,
    this.errorBuilder,
    this.designWidth = 214,
    this.designHeight = 286,
  });

  final String pic;
  final BoxFit fit;
  final ImageErrorWidgetBuilder? errorBuilder;
  final double designWidth;
  final double designHeight;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final w = (designWidth * dpr).round().clamp(1, 720);
    final h = (designHeight * dpr).round().clamp(1, 960);
    return KotvNetworkImage(
      pic,
      fit: fit,
      cacheWidth: w,
      cacheHeight: h,
      singleFrame: true,
      gaplessPlayback: false,
      errorBuilder: errorBuilder,
    );
  }
}
