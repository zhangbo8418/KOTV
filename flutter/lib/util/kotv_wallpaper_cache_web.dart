import 'dart:typed_data';

/// Web：不落盘，每次启动重新取图。
Future<({String url, Uint8List bytes, DateTime fetchedAt})?> wallDiskLoad() async => null;

Future<void> wallDiskSave(String url, Uint8List bytes) async {}

Future<void> wallDiskClear() async {}
