import 'dart:typed_data';

/// Web：无本地壁纸文件缓存。
Future<Uint8List?> kotvReadWallpaperBytes(String url) async => null;

Future<void> kotvPersistWallpaper(String url) async {}

Future<({String url, String path})?> kotvLoadWallpaperDisk() async => null;

Future<void> kotvClearWallpaperDisk() async {}
