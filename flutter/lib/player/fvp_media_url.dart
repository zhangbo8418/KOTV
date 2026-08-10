import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// FVP/libmdk 开播 URL：伪扩展名（`?id=1.m3u8` 实为 FLV）时，用 [mdkopt] 强制 demux。
///
/// 见 https://github.com/wang-bin/mdk-sdk/wiki/Player-APIs — `mdkopt=avformat&input=flv`
String kotvFvpMediaUrl(String url, {String? inputFormat}) {
  final fmt = (inputFormat ?? '').trim();
  if (fmt.isEmpty) return url;
  if (url.contains('mdkopt=')) return url;
  final sep = url.contains('?') ? '&' : '?';
  return '$url${sep}mdkopt=avformat&input=$fmt';
}

/// 轻量探测容器：读魔数 / `#EXTM3U`。失败返回 null（交给 mdk 自探测）。
Future<String?> kotvProbeAvInputFormat(
  String url, {
  Map<String, String>? headers,
}) async {
  if (url.isEmpty || !(url.startsWith('http://') || url.startsWith('https://'))) {
    return null;
  }
  final client = HttpClient();
  client.connectionTimeout = const Duration(seconds: 4);
  client.autoUncompress = false;
  try {
    final req = await client.getUrl(Uri.parse(url));
    headers?.forEach((k, v) {
      if (k.trim().isEmpty || v.trim().isEmpty) return;
      req.headers.set(k, v);
    });
    req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-2047');
    final res = await req.close().timeout(const Duration(seconds: 8));
    final buf = BytesBuilder(copy: false);
    await for (final chunk in res) {
      buf.add(chunk);
      if (buf.length >= 16) break;
    }
    return _guessInputFormat(buf.takeBytes());
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

String? _guessInputFormat(Uint8List bytes) {
  if (bytes.length >= 3 && bytes[0] == 0x46 && bytes[1] == 0x4c && bytes[2] == 0x56) {
    return 'flv';
  }
  if (bytes.isNotEmpty && bytes[0] == 0x47) {
    return 'mpegts';
  }
  final head = utf8.decode(
    bytes.length > 96 ? bytes.sublist(0, 96) : bytes,
    allowMalformed: true,
  );
  if (head.contains('#EXTM3U')) return 'hls';
  return null;
}
