import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
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

  test('plain doubanio gets movie.douban.com Referer', () {
    final p = kotvParseImageUrl(
      'https://img2.doubanio.com/view/photo/s_ratio_poster/public/p2935130131.jpg',
    );
    expect(p.headers['Referer'], 'https://movie.douban.com/');
    expect(p.headers['User-Agent'], isNotEmpty);
  });

  test('explicit Referer is kept for doubanio', () {
    final p = kotvParseImageUrl(
      'https://img1.doubanio.com/view/photo/s_ratio_poster/public/p1.jpg'
      '@Referer=https://www.douban.com/',
    );
    expect(p.headers['Referer'], 'https://www.douban.com/');
  });

  test('decodes a data image and rejects a short payload', () {
    final png = kotvDecodeDataImage(
      'data:image/png;base64,iVBORw0KGgo=',
    );
    expect(png, isNotNull);
    expect(png, isNotEmpty);
    expect(kotvDecodeDataImage('data:text/plain;base64,YQ=='), isNull);
    expect(kotvDecodeDataImage('https://example.com/a.jpg'), isNull);
  });

  test('gif stays multi-frame after scaling, png is one frame', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final gif = Uint8List.fromList(const [
      71, 73, 70, 56, 57, 97, 2, 0, 2, 0, 129, 0, 0, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 33, 255, 11, 78, 69, 84, 83, 67, 65, 80, 69, 50, 46, 48, 3, 1, 0, 0, 0, 33, 249, 4, 8, 10, 0, 0, 0, 44, 0, 0, 0, 0, 2, 0, 2, 0, 0, 8, 6, 0, 1, 8, 4, 16, 16, 0, 33, 249, 4, 8, 10, 0, 0, 0, 44, 0, 0, 0, 0, 2, 0, 2, 0, 129, 0, 0, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 8, 6, 0, 1, 8, 4, 16, 16, 0, 59,
    ]);
    final png = Uint8List.fromList(const [
      137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 2, 0, 0, 0, 2, 8, 2, 0, 0, 0, 253, 212, 154, 115, 0, 0, 0, 19, 73, 68, 65, 84, 120, 156, 99, 100, 248, 207, 192, 192, 192, 192, 4, 34, 24, 24, 0, 12, 30, 1, 3, 172, 216, 139, 167, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
    ]);

    Future<List<int>> rgba(ui.Image image) async {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      return data!.buffer.asUint8List().toList();
    }

    final gifCodec = await ui.instantiateImageCodec(gif, targetWidth: 1);
    expect(gifCodec.frameCount, greaterThan(1));
    final a = await gifCodec.getNextFrame();
    final b = await gifCodec.getNextFrame();
    expect(await rgba(a.image), isNot(await rgba(b.image)));
    a.image.dispose();
    b.image.dispose();
    gifCodec.dispose();

    final pngCodec = await ui.instantiateImageCodec(png);
    expect(pngCodec.frameCount, 1);
    final still = await pngCodec.getNextFrame();
    still.image.dispose();
    pngCodec.dispose();
  });

  testWidgets('frame widget can leave without disposing twice', (tester) async {
    final png = Uint8List.fromList(const [
      137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 2, 0, 0, 0, 2, 8, 2, 0, 0, 0, 253, 212, 154, 115, 0, 0, 0, 19, 73, 68, 65, 84, 120, 156, 99, 100, 248, 207, 192, 192, 192, 192, 4, 34, 24, 24, 0, 12, 30, 1, 3, 172, 216, 139, 167, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
    ]);
    await tester.pumpWidget(MaterialApp(home: KotvFrameImage(bytes: png)));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}
