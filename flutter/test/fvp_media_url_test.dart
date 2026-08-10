import 'package:flutter_test/flutter_test.dart';
import 'package:kotv/player/fvp_media_url.dart';

void main() {
  test('resolve leaves non-http unchanged', () async {
    expect(await kotvResolveFvpMediaUrl('file:///tmp/a.mp4'), 'file:///tmp/a.mp4');
    expect(await kotvResolveFvpMediaUrl(''), '');
  });
}
