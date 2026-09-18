import 'dart:io';

Future<String?> readDanmakuFileText(String path) async {
  final p = path.trim();
  if (p.isEmpty) return null;
  try {
    var filePath = p;
    if (p.startsWith('file:')) {
      filePath = Uri.parse(p).toFilePath();
    }
    final f = File(filePath);
    if (!await f.exists()) return null;
    return f.readAsString();
  } catch (_) {
    return null;
  }
}
