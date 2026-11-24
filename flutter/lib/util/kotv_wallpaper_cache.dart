import 'dart:async';

import 'package:flutter/foundation.dart';

import '../widgets/kotv_network_image.dart';
import 'kotv_wallpaper_cache_io.dart' if (dart.library.html) 'kotv_wallpaper_cache_web.dart';

/// 缓存的壁纸超过这个时长就在后台重取（同一地址可能每次返回不同的图，如每日 Bing）；
/// 重取期间及失败时照旧显示缓存。
const kotvWallpaperMaxAge = Duration(hours: 6);

/// 一张取到的壁纸：来源地址、图片字节、取图时间。
class KotvWallpaper {
  const KotvWallpaper(this.url, this.bytes, this.fetchedAt);

  final String url;
  final Uint8List bytes;
  final DateTime fetchedAt;

  bool get fresh => DateTime.now().difference(fetchedAt) < kotvWallpaperMaxAge;
}

/// 上次取到的壁纸，冷启动先显示它，不等设置和网络。
Future<KotvWallpaper?> kotvLoadWallpaperDisk() async {
  try {
    final hit = await wallDiskLoad();
    if (hit == null || !_looksLikeImage(hit.bytes)) return null;
    return KotvWallpaper(hit.url, hit.bytes, hit.fetchedAt);
  } catch (e) {
    debugPrint('wallpaper: 读缓存失败 $e');
    return null;
  }
}

/// 取图并落盘。取不到或不是图片返回 null（调用方换下一个候选或保留旧图）。
Future<KotvWallpaper?> kotvFetchWallpaper(String url) async {
  final req = kotvResolveImageRequest(url);
  if (!(req.url.startsWith('http://') || req.url.startsWith('https://'))) return null;
  try {
    final bytes = await kotvFetchImageBytes(req.url, req.headers).timeout(const Duration(seconds: 30));
    if (!_looksLikeImage(bytes)) {
      debugPrint('wallpaper: 不是图片 $url');
      return null;
    }
    try {
      await wallDiskSave(url, bytes);
    } catch (e) {
      debugPrint('wallpaper: 写缓存失败 $e');
    }
    return KotvWallpaper(url, bytes, DateTime.now());
  } catch (e) {
    debugPrint('wallpaper: 取图失败 $url $e');
    return null;
  }
}

Future<void> kotvClearWallpaperDisk() async {
  try {
    await wallDiskClear();
  } catch (_) {}
}

bool _looksLikeImage(Uint8List b) {
  if (b.length < 12) return false;
  if (b[0] == 0xFF && b[1] == 0xD8) return true; // JPEG
  if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) return true; // PNG
  if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) return true; // GIF
  if (b[0] == 0x42 && b[1] == 0x4D) return true; // BMP
  return b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 && // RIFF…WEBP
      b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50;
}
