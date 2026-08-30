import 'package:flutter_test/flutter_test.dart';

import 'package:kotv/widgets/kotv_network_image.dart';

void main() {
  test('parses @Headers JSON and strips from url', () {
    const raw =
        'https://img1.doubanio.com/view/photo/s_ratio_poster/public/p2934934225.jpg'
        '@Headers={"User-Agent":"Mozilla/5.0","Referer":"https://www.douban.com"}';
    final p = kotvParseImageUrl(raw);
    expect(p.url, 'https://img1.doubanio.com/view/photo/s_ratio_poster/public/p2934934225.jpg');
    expect(p.headers['Referer'], 'https://www.douban.com');
    expect(p.headers['User-Agent'], 'Mozilla/5.0');
  });

  test('parses @Referer= style', () {
    const raw =
        'https://img9.doubanio.com/view/photo/s_ratio_poster/public/p2552058346.jpg'
        '@Referer=https://movie.douban.com/';
    final p = kotvParseImageUrl(raw);
    expect(p.url.endsWith('.jpg'), isTrue);
    expect(p.headers['Referer'], 'https://movie.douban.com/');
    expect(p.headers['User-Agent'], isNotEmpty);
  });

  test('plain url gets default UA', () {
    final p = kotvParseImageUrl('https://example.com/a.jpg');
    expect(p.url, 'https://example.com/a.jpg');
    expect(p.headers['User-Agent'], kotvDefaultImageUa);
  });
}
