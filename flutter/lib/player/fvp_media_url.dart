import 'dart:io';

/// 解析播放地址的跳转链，返回最终可播 URL。
///
/// 直播网关（如 bobohome）常对 `/migu`、`/fengshows` 返回 **302 → http CDN**；
/// 体为空。Windows 上 libmdk/FFmpeg 若未跟跳，prepare 会失败并显示
/// `invalid or unsupported media`。最终地址自带真实路径（`.flv` / `index.m3u8`），
/// **不按查询串扩展名猜测，也不强行 mdkopt**，交给 demuxer 按内容协商。
Future<String> kotvResolveFvpMediaUrl(
  String url, {
  Map<String, String>? headers,
}) async {
  if (url.isEmpty || !(url.startsWith('http://') || url.startsWith('https://'))) {
    return url;
  }
  final client = HttpClient();
  client.connectionTimeout = const Duration(seconds: 5);
  client.autoUncompress = false;
  var current = Uri.parse(url);
  try {
    for (var hop = 0; hop < 8; hop++) {
      final req = await client.getUrl(current);
      req.followRedirects = false;
      headers?.forEach((k, v) {
        if (k.trim().isEmpty || v.trim().isEmpty) return;
        req.headers.set(k, v);
      });
      final res = await req.close().timeout(const Duration(seconds: 10));
      final code = res.statusCode;
      if (code >= 300 && code < 400) {
        final loc = res.headers.value(HttpHeaders.locationHeader)?.trim();
        await res.drain<void>().catchError((_) {});
        if (loc == null || loc.isEmpty) return current.toString();
        current = current.resolve(loc);
        continue;
      }
      // 最终响应：立刻掐断，避免拖住直播 FLV
      try {
        final socket = await res.detachSocket();
        socket.destroy();
      } catch (_) {
        await res.drain<void>().catchError((_) {});
      }
      return current.toString();
    }
    return current.toString();
  } catch (_) {
    return url;
  } finally {
    client.close(force: true);
  }
}
