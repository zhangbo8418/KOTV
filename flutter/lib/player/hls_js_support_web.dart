import 'dart:js_interop';

@JS('Hls')
extension type _Hls._(JSObject _) implements JSObject {
  external static bool isSupported();
}

/// 当前页的 hls.js 会接管媒体请求时为真。Safari 上该方法为假，走原生 HLS。
bool kotvWebHlsJsSupported() {
  try {
    return _Hls.isSupported();
  } catch (_) {
    return false;
  }
}
