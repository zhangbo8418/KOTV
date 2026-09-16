import 'package:flutter_test/flutter_test.dart';
import 'package:kotv/player/disc_play.dart';

void main() {
  test('ISO → dvd:// + dvd-device', () {
    final r = KotvDiscPlay.rewrite('/sdcard/Movies/movie.iso');
    expect(r.forceMpv, isTrue);
    expect(r.url, 'dvd://');
    expect(r.props['dvd-device'], '/sdcard/Movies/movie.iso');
  });

  test('VIDEO_TS folder → dvd device root', () {
    final r = KotvDiscPlay.rewrite('/data/VIDEO_TS/VTS_01_1.VOB');
    expect(r.url, 'dvd://');
    expect(r.props['dvd-device'], '/data');
  });

  test('BDMV → bd:// + bluray-device', () {
    final r = KotvDiscPlay.rewrite('/mnt/disc/BDMV/STREAM/00000.m2ts');
    expect(r.url, 'bd://');
    expect(r.props['bluray-device'], '/mnt/disc');
  });

  test('looksLike rejects http', () {
    expect(KotvDiscPlay.looksLike('https://cdn.example/a.m3u8'), isFalse);
    expect(KotvDiscPlay.looksLike('dvd://'), isTrue);
  });
}
