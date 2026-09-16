import 'package:flutter_test/flutter_test.dart';
import 'package:kotv/player/drm_opts.dart';

void main() {
  test('local ClearKey kid:key → hex', () {
    final drm = {
      'type': 'clearkey',
      'key': '00112233445566778899aabbccddeeff:ffeeddccbbaa99887766554433221100',
    };
    expect(kotvIsLocalClearKey(drm), isTrue);
    expect(kotvClearKeyHex(drm), 'ffeeddccbbaa99887766554433221100');
    expect(kotvLavfOWithClearKey(kotvClearKeyHex(drm)), contains('decryption_key=ffeeddccbbaa99887766554433221100'));
  });

  test('http license not local', () {
    expect(
      kotvIsLocalClearKey({'type': 'clearkey', 'key': 'https://x/license'}),
      isFalse,
    );
  });
}
