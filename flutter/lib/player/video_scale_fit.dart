import 'package:flutter/widgets.dart';

/// 将设置里的 videoScale（default/fill/zoom/16:9/4:3）映射为 Flutter [BoxFit]。
/// `16:9` / `4:3` 不走 stretch（[BoxFit.fill]）；由 [kotvForcedAspectRatio] + 布局强制画幅。
/// Exo Texture 与 FVP 共用；MPV 走 keepaspect / video-aspect-override。
BoxFit kotvFitFromVideoScale(String scale, BoxFit fallback) {
  switch (scale.trim().toLowerCase()) {
    case 'fill':
      return BoxFit.fill;
    case 'zoom':
      return BoxFit.cover;
    case '16:9':
    case '4:3':
    case 'default':
      return BoxFit.contain;
    default:
      return fallback;
  }
}

/// 强制画幅；非 16:9/4:3 返回 null。
double? kotvForcedAspectRatio(String scale) {
  switch (scale.trim().toLowerCase()) {
    case '16:9':
      return 16 / 9;
    case '4:3':
      return 4 / 3;
    default:
      return null;
  }
}

/// 在视口内按 videoScale 计算实际绘制区域尺寸。
Size kotvBoxForVideoScale(Size viewport, Size video, String scale) {
  final forced = kotvForcedAspectRatio(scale);
  if (forced != null) {
    return _containAspect(viewport, forced);
  }
  final fit = kotvFitFromVideoScale(scale, BoxFit.contain);
  if (fit == BoxFit.fill || video.width <= 0 || video.height <= 0) {
    return viewport;
  }
  final ar = video.width / video.height;
  final vr = viewport.width / viewport.height;
  switch (fit) {
    case BoxFit.cover:
      if (ar > vr) return Size(viewport.height * ar, viewport.height);
      return Size(viewport.width, viewport.width / ar);
    default:
      return _containAspect(viewport, ar);
  }
}

Size _containAspect(Size viewport, double aspect) {
  if (aspect <= 0 || !aspect.isFinite) return viewport;
  final vr = viewport.width / viewport.height;
  if (aspect > vr) return Size(viewport.width, viewport.width / aspect);
  return Size(viewport.height * aspect, viewport.height);
}

/// 交给原生 Exo setFit 的名字：强制画幅在 Flutter 布局完成，原生用 contain。
String kotvNativeFitName(String scale) {
  switch (scale.trim().toLowerCase()) {
    case 'fill':
      return 'fill';
    case 'zoom':
      return 'cover';
    default:
      return 'contain';
  }
}
