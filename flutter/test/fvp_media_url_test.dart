import 'package:flutter_test/flutter_test.dart';
import 'package:kotv/player/fvp_media_url.dart';

void main() {
  test('mdkopt append', () {
    expect(
      kotvFvpMediaUrl('https://a/b?id=1.m3u8', inputFormat: 'flv'),
      'https://a/b?id=1.m3u8&mdkopt=avformat&input=flv',
    );
    expect(kotvFvpMediaUrl('https://a/b', inputFormat: 'hls'), 'https://a/b?mdkopt=avformat&input=hls');
    expect(kotvFvpMediaUrl('https://a/b?mdkopt=x', inputFormat: 'flv'), 'https://a/b?mdkopt=x');
  });
}
