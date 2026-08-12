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
    var pos = Duration.zero;
    Future<void>.delayed(const Duration(milliseconds: 350), () {
      buffering = false;
      size = true;
      pos = const Duration(milliseconds: 500);
    });
    await kotvGuardSilentVideo(
      hasVideoSize: () => size,
      isBuffering: () => buffering,
      sessionAlive: () => size,
      isPlaying: () => size,
      position: () => pos,
      duration: () => const Duration(minutes: 3),
      hasVideoSource: () => true,
      blackScreenTimeout: const Duration(milliseconds: 80),
      sizeSettleTimeout: const Duration(milliseconds: 60),
      progressStallTimeout: const Duration(milliseconds: 400),
      progressMinDelta: const Duration(milliseconds: 100),
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
    var pos = Duration.zero;
    await kotvGuardSilentVideo(
      hasVideoSize: () => size,
      isBuffering: () => false,
      sessionAlive: () => true,
      isPlaying: () => true,
      position: () => pos,
      duration: () => const Duration(minutes: 10),
      hasVideoSource: () => true,
      onFixVideoSource: () async {
        size = true;
        pos = const Duration(milliseconds: 600);
      },
      blackScreenTimeout: const Duration(milliseconds: 200),
      sizeSettleTimeout: const Duration(milliseconds: 60),
      progressStallTimeout: const Duration(milliseconds: 400),
      progressMinDelta: const Duration(milliseconds: 100),
      tick: const Duration(milliseconds: 40),
    );
  });

  test('playing with size but stuck progress fails', () async {
    var threw = false;
    String? msg;
    try {
      await kotvGuardSilentVideo(
        hasVideoSize: () => true,
        isBuffering: () => false,
        sessionAlive: () => true,
        isPlaying: () => true,
        position: () => Duration.zero,
        duration: () => const Duration(minutes: 5),
        hasVideoSource: () => true,
        sizeSettleTimeout: const Duration(milliseconds: 40),
        progressStallTimeout: const Duration(milliseconds: 200),
        progressMinDelta: const Duration(milliseconds: 100),
        tick: const Duration(milliseconds: 40),
      );
    } on KotvSilentVideoException catch (e) {
      threw = true;
      msg = e.message;
    }
    expect(threw, isTrue);
    expect(msg, contains('进度'));
  });

  test('playing+buffering does not count as progress stall', () async {
    var pos = Duration.zero;
    Future<void>.delayed(const Duration(milliseconds: 280), () {
      pos = const Duration(milliseconds: 500);
    });
    await kotvGuardSilentVideo(
      hasVideoSize: () => true,
      isBuffering: () => true,
      sessionAlive: () => true,
      isPlaying: () => true,
      position: () => pos,
      duration: () => const Duration(minutes: 5),
      hasVideoSource: () => true,
      sizeSettleTimeout: const Duration(milliseconds: 40),
      progressStallTimeout: const Duration(milliseconds: 120),
      progressMinDelta: const Duration(milliseconds: 100),
      tick: const Duration(milliseconds: 40),
    );
  });

  test('progress stall starts only after buffering ends', () async {
    var buffering = true;
    Future<void>.delayed(const Duration(milliseconds: 180), () {
      buffering = false;
    });
    var threw = false;
    try {
      await kotvGuardSilentVideo(
        hasVideoSize: () => true,
        isBuffering: () => buffering,
        sessionAlive: () => true,
        isPlaying: () => true,
        position: () => Duration.zero,
        duration: () => const Duration(minutes: 5),
        hasVideoSource: () => true,
        sizeSettleTimeout: const Duration(milliseconds: 40),
        progressStallTimeout: const Duration(milliseconds: 150),
        progressMinDelta: const Duration(milliseconds: 100),
        tick: const Duration(milliseconds: 40),
      );
    } on KotvSilentVideoException catch (e) {
      threw = true;
      expect(e.message, contains('进度'));
    }
    expect(threw, isTrue);
  });

  test('playing with size and advancing progress succeeds', () async {
    var pos = Duration.zero;
    Future<void>.delayed(const Duration(milliseconds: 80), () {
      pos = const Duration(milliseconds: 500);
    });
    await kotvGuardSilentVideo(
      hasVideoSize: () => true,
      isBuffering: () => false,
      sessionAlive: () => true,
      isPlaying: () => true,
      position: () => pos,
      duration: () => const Duration(minutes: 5),
      hasVideoSource: () => true,
      sizeSettleTimeout: const Duration(milliseconds: 40),
      progressStallTimeout: const Duration(milliseconds: 400),
      progressMinDelta: const Duration(milliseconds: 100),
      tick: const Duration(milliseconds: 40),
    );
  });
}
