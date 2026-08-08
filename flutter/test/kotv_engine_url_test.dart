import 'package:flutter_test/flutter_test.dart';

import 'package:kotv/api/kotv_engine_url.dart';

void main() {
  test('normalize keeps https and defaults bare host to http', () {
    expect(kotvNormalizeEngineBaseUrl('https://tv.example.com'), 'https://tv.example.com');
    expect(kotvNormalizeEngineBaseUrl('https://tv.example.com/'), 'https://tv.example.com');
    expect(kotvNormalizeEngineBaseUrl('HTTP://10.0.0.8:9978'), 'http://10.0.0.8:9978');
    expect(kotvNormalizeEngineBaseUrl('10.0.0.8:9978'), 'http://10.0.0.8:9978');
    expect(kotvNormalizeEngineBaseUrl(''), '');
  });

  test('local detection ignores scheme', () {
    expect(kotvIsLocalEngineBaseUrl('https://127.0.0.1:9978'), isTrue);
    expect(kotvIsLocalEngineBaseUrl('http://192.168.1.8:9978'), isFalse);
    expect(kotvIsLocalEngineBaseUrl('https://tv.example.com'), isFalse);
  });

  test('rewrite loopback proxy to remote engine host', () {
    expect(
      kotvRewriteEngineLocalUrl(
        'http://127.0.0.1:9978/proxy/play?id=abc',
        'http://192.168.1.8:9978',
      ),
      'http://192.168.1.8:9978/proxy/play?id=abc',
    );
    expect(
      kotvRewriteEngineLocalUrl(
        'http://cdn.example/a.m3u8',
        'http://192.168.1.8:9978',
      ),
      'http://cdn.example/a.m3u8',
    );
    expect(
      kotvRewriteEngineLocalUrl(
        'http://127.0.0.1:9978/proxy/cached_m3u8?id=1',
        'http://127.0.0.1:9978',
      ),
      'http://127.0.0.1:9978/proxy/cached_m3u8?id=1',
    );
  });
}
