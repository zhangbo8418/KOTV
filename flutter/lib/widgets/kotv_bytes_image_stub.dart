import 'package:flutter/painting.dart';

/// 浏览器图片不走 dart:io。请求头由浏览器自己带。
ImageProvider kotvBytesImageProvider(String url, Map<String, String> headers) {
  return NetworkImage(url, headers: headers.isEmpty ? null : headers);
}
