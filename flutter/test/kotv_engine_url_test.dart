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
}
