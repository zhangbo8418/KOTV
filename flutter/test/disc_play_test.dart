import 'package:flutter_test/flutter_test.dart';
import 'package:kotv/player/disc_play.dart';

void main() {
  test('ISO → force-iso on original path', () {
    final r = KotvDiscPlay.openPlan('/sdcard/Movies/movie.iso');
    expect(r, isNotNull);
    expect(r!.forceMpv, isTrue);
    expect(r.url, '/sdcard/Movies/movie.iso');
    expect(r.props['force-iso'], 'yes');
  });

  test('http ISO → force-iso keeps URL', () {
    final r = KotvDiscPlay.openPlan('https://cdn.example/film.iso');
    expect(r, isNotNull);
    expect(r!.url, 'https://cdn.example/film.iso');
    expect(r.props['force-iso'], 'yes');
    expect(KotvDiscPlay.looksLike('https://cdn.example/film.iso'), isTrue);
  });

  test('VIDEO_TS folder → dvd device root', () {
    final r = KotvDiscPlay.openPlan('/data/VIDEO_TS/VTS_01_1.VOB');
    expect(r!.url, 'dvd://');
    expect(r.props['dvd-device'], '/data');
  });

  test('BDMV → bd:// + bluray-device', () {
    final r = KotvDiscPlay.openPlan('/mnt/disc/BDMV/STREAM/00000.m2ts');
    expect(r!.url, 'bd://');
    expect(r.props['bluray-device'], '/mnt/disc');
  });

  test('looksLike rejects non-iso http', () {
    expect(KotvDiscPlay.looksLike('https://cdn.example/a.m3u8'), isFalse);
    expect(KotvDiscPlay.looksLike('dvd://'), isTrue);
  });

  test('openPlanAny / looksLikeAny pick first disc candidate', () {
    expect(
      KotvDiscPlay.looksLikeAny(['https://cdn.example/a.m3u8', '/a.iso']),
      isTrue,
    );
    final r = KotvDiscPlay.openPlanAny(['https://x/a.m3u8', '/mnt/film.iso']);
    expect(r!.url, '/mnt/film.iso');
    expect(r.props['force-iso'], 'yes');
  });
}
