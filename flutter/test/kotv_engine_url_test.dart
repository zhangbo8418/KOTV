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

  test('effective defaults empty/malformed to local 9978', () {
    expect(kotvEffectiveEngineBaseUrl(''), kotvDefaultLocalEngineBaseUrl);
    expect(kotvEffectiveEngineBaseUrl('http://'), kotvDefaultLocalEngineBaseUrl);
    expect(kotvEffectiveEngineBaseUrl('http://:9978'), kotvDefaultLocalEngineBaseUrl);
    expect(kotvEffectiveEngineBaseUrl('ftp://tv.example.com'), kotvDefaultLocalEngineBaseUrl);
    expect(kotvEffectiveEngineBaseUrl('http://10.0.0.8'), 'http://10.0.0.8:9978');
    expect(kotvEffectiveEngineBaseUrl('https://tv.example.com'), 'https://tv.example.com');
    expect(kotvEffectiveEngineBaseUrl('https://tv.example.com:8443'), 'https://tv.example.com:8443');
  });

  test('store writes empty for local/invalid', () {
    expect(kotvStoreEngineBaseUrl(''), '');
    expect(kotvStoreEngineBaseUrl('http://127.0.0.1:9978'), '');
    expect(kotvStoreEngineBaseUrl('http://'), '');
    expect(kotvStoreEngineBaseUrl('ftp://tv.example.com'), '');
    expect(kotvStoreEngineBaseUrl('10.0.0.8'), 'http://10.0.0.8:9978');
    expect(kotvStoreEngineBaseUrl('https://tv.example.com'), 'https://tv.example.com');
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

  test('rewrites engine path onto the filled connection origin', () {
    expect(
      kotvRewriteEngineLocalUrl(
        'http://192.168.0.113:9978/proxy/play?id=abc',
        'https://tv.example.com:8443',
      ),
      'https://tv.example.com:8443/proxy/play?id=abc',
    );
    expect(
      kotvRewriteEngineLocalUrl(
        'http://tv.example.com:9978/file/a.jpg',
        'https://tv.example.com:8443',
      ),
      'https://tv.example.com:8443/file/a.jpg',
    );
  });

  test('keeps a private url that is not an engine path', () {
    expect(
      kotvRewriteEngineLocalUrl(
        'http://10.0.0.2:8080/live.m3u8',
        'https://tv.example.com:8443',
      ),
      'http://10.0.0.2:8080/live.m3u8',
    );
  });

  test('keeps a loopback url whose port is not the engine port', () {
    expect(
      kotvRewriteEngineLocalUrl(
        'http://127.0.0.1:5266/fishplay/go/quark/32t/abc',
        'http://192.168.1.8:9978',
      ),
      'http://127.0.0.1:5266/fishplay/go/quark/32t/abc',
    );
  });

  test('rewrite private LAN proxy to configured server host', () {
    expect(
      kotvRewriteEngineLocalUrl(
        'http://192.168.1.8:9978/proxy/play?id=abc',
        'https://tv.example.com',
      ),
      'https://tv.example.com/proxy/play?id=abc',
    );
  });
}
