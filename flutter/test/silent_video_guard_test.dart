import 'package:flutter_test/flutter_test.dart';
import 'package:kotv/player/kotv_playback.dart';
import 'package:kotv/player/silent_video_guard.dart';

void main() {
  test('black screen without buffering fails in ~5s', () async {
    final sw = Stopwatch()..start();
    var threw = false;
    try {
      await kotvGuardSilentVideo(
        hasVideoSize: () => false,
        isBuffering: () => false,
        sessionAlive: () => true,
        blackScreenTimeout: const Duration(milliseconds: 300),
        bufferingTimeout: const Duration(seconds: 5),
        tick: const Duration(milliseconds: 50),
      );
    } on KotvSilentVideoException {
      threw = true;
    }
    expect(threw, isTrue);
    expect(sw.elapsedMilliseconds, lessThan(2000));
  });

  test('buffering waits longer than black-screen window', () async {
    final sw = Stopwatch()..start();
    var buffering = true;
    Future<void>.delayed(const Duration(milliseconds: 400), () {
      buffering = false;
    });
    var threw = false;
    try {
      await kotvGuardSilentVideo(
        hasVideoSize: () => false,
        isBuffering: () => buffering,
        sessionAlive: () => true,
        blackScreenTimeout: const Duration(milliseconds: 200),
        bufferingTimeout: const Duration(milliseconds: 900),
        tick: const Duration(milliseconds: 50),
      );
    } on KotvSilentVideoException {
      threw = true;
    }
    expect(threw, isTrue);
    // Must survive past black-screen window while buffering.
    expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(350));
  });

  test('size appearing while buffering succeeds', () async {
    var size = false;
    Future<void>.delayed(const Duration(milliseconds: 150), () {
      size = true;
    });
    await kotvGuardSilentVideo(
      hasVideoSize: () => size,
      isBuffering: () => !size,
      sessionAlive: () => true,
      blackScreenTimeout: const Duration(milliseconds: 100),
      bufferingTimeout: const Duration(seconds: 2),
      tick: const Duration(milliseconds: 40),
    );
  });
}
