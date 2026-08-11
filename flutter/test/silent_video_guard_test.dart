import 'package:flutter_test/flutter_test.dart';
import 'package:kotv/player/kotv_playback.dart';
import 'package:kotv/player/silent_video_guard.dart';

void main() {
  test('black screen without buffering fails after fix + black window', () async {
    final sw = Stopwatch()..start();
    var threw = false;
    var fixes = 0;
    try {
      await kotvGuardSilentVideo(
        hasVideoSize: () => false,
        isBuffering: () => false,
        sessionAlive: () => true,
        hasVideoSource: () => true,
        onFixVideoSource: () async {
          fixes++;
        },
        blackScreenTimeout: const Duration(milliseconds: 200),
        sourceFixTimeout: const Duration(milliseconds: 100),
        sizeSettleTimeout: const Duration(milliseconds: 40),
        tick: const Duration(milliseconds: 40),
      );
    } on KotvSilentVideoException {
      threw = true;
    }
    expect(threw, isTrue);
    expect(fixes, greaterThanOrEqualTo(1));
    expect(sw.elapsedMilliseconds, lessThan(3000));
  });

  test('audio-only succeeds without video size', () async {
    await kotvGuardSilentVideo(
      hasVideoSize: () => false,
      isBuffering: () => false,
      sessionAlive: () => true,
      isAudioOnly: () => true,
      hasVideoSource: () => false,
      blackScreenTimeout: const Duration(milliseconds: 50),
      sizeSettleTimeout: const Duration(milliseconds: 20),
      tick: const Duration(milliseconds: 20),
    );
  });

  test('missing video source throws after sourceFixTimeout', () async {
    var threw = false;
    String? msg;
    try {
      await kotvGuardSilentVideo(
        hasVideoSize: () => false,
        isBuffering: () => false,
        sessionAlive: () => true,
        hasVideoSource: () => false,
        onFixVideoSource: () async {},
        sourceFixTimeout: const Duration(milliseconds: 250),
        blackScreenTimeout: const Duration(seconds: 5),
        sizeSettleTimeout: const Duration(milliseconds: 40),
        tick: const Duration(milliseconds: 40),
      );
    } on KotvSilentVideoException catch (e) {
      threw = true;
      msg = e.message;
    }
    expect(threw, isTrue);
    expect(msg, contains('视频源'));
  });

  test('pre-play buffering waits until size without failing', () async {
    var size = false;
    var buffering = true;
    Future<void>.delayed(const Duration(milliseconds: 350), () {
      buffering = false;
      size = true;
    });
    await kotvGuardSilentVideo(
      hasVideoSize: () => size,
      isBuffering: () => buffering,
      sessionAlive: () => false,
      hasVideoSource: () => true,
      blackScreenTimeout: const Duration(milliseconds: 80),
      sizeSettleTimeout: const Duration(milliseconds: 60),
      tick: const Duration(milliseconds: 40),
    );
  });

  test('playing black despite buffering flag still fails', () async {
    final sw = Stopwatch()..start();
    var threw = false;
    try {
      await kotvGuardSilentVideo(
        hasVideoSize: () => false,
        isBuffering: () => true,
        sessionAlive: () => true,
        hasVideoSource: () => true,
        blackScreenTimeout: const Duration(milliseconds: 150),
        sizeSettleTimeout: const Duration(milliseconds: 40),
        tick: const Duration(milliseconds: 40),
      );
    } on KotvSilentVideoException {
      threw = true;
    }
    expect(threw, isTrue);
    expect(sw.elapsedMilliseconds, lessThan(2500));
  });

  test('long pre-play buffering then black screen fails after black window', () async {
    final sw = Stopwatch()..start();
    var buffering = true;
    var alive = false;
    Future<void>.delayed(const Duration(milliseconds: 300), () {
      buffering = false;
      alive = true;
    });
    var threw = false;
    try {
      await kotvGuardSilentVideo(
        hasVideoSize: () => false,
        isBuffering: () => buffering,
        sessionAlive: () => alive,
        hasVideoSource: () => true,
        blackScreenTimeout: const Duration(milliseconds: 150),
        sizeSettleTimeout: const Duration(milliseconds: 40),
        tick: const Duration(milliseconds: 40),
      );
    } on KotvSilentVideoException {
      threw = true;
    }
    expect(threw, isTrue);
    expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(350));
  });

  test('dead session throws SilentVideo', () async {
    var threw = false;
    try {
      await kotvGuardSilentVideo(
        hasVideoSize: () => false,
        isBuffering: () => false,
        sessionAlive: () => false,
        hasVideoSource: () => true,
        sessionDeadTimeout: const Duration(milliseconds: 80),
        blackScreenTimeout: const Duration(milliseconds: 500),
        sizeSettleTimeout: const Duration(milliseconds: 40),
        tick: const Duration(milliseconds: 20),
      );
    } on KotvSilentVideoException {
      threw = true;
    }
    expect(threw, isTrue);
  });

  test('size flicker does not count as success', () async {
    var size = true;
    Future<void>.delayed(const Duration(milliseconds: 80), () {
      size = false;
    });
    var threw = false;
    try {
      await kotvGuardSilentVideo(
        hasVideoSize: () => size,
        isBuffering: () => false,
        sessionAlive: () => true,
        hasVideoSource: () => true,
        blackScreenTimeout: const Duration(milliseconds: 200),
        sizeSettleTimeout: const Duration(milliseconds: 200),
        tick: const Duration(milliseconds: 40),
      );
    } on KotvSilentVideoException {
      threw = true;
    }
    expect(threw, isTrue);
  });

  test('fix video source that unlocks size succeeds', () async {
    var size = false;
    await kotvGuardSilentVideo(
      hasVideoSize: () => size,
      isBuffering: () => false,
      sessionAlive: () => true,
      hasVideoSource: () => true,
      onFixVideoSource: () async {
        size = true;
      },
      blackScreenTimeout: const Duration(milliseconds: 200),
      sizeSettleTimeout: const Duration(milliseconds: 60),
      tick: const Duration(milliseconds: 40),
    );
  });
}
