import 'package:flutter_test/flutter_test.dart';

import 'package:kotv/player/playback_failover.dart';

void main() {
  test('hard flips soft then next player restores settings decode', () {
    final f = KotvPlaybackFailover(playerVal: 'innie#mpv', decodeMode: 'hard');
    f.markAttempt();
    final flip = f.nextStep();
    expect(flip, isNotNull);
    expect(flip!.kind, KotvFailoverKind.flipDecode);
    expect(flip.decodeMode, 'soft');
    expect(f.decodeMode, 'soft');

    final next = f.nextStep();
    expect(next, isNotNull);
    expect(next!.kind, KotvFailoverKind.nextPlayer);
    expect(next.playerVal, 'innie#fvp');
    expect(next.decodeMode, 'hard');
  });

  test('auto skips decode flip', () {
    final f = KotvPlaybackFailover(playerVal: 'innie#mpv', decodeMode: 'auto');
    f.markAttempt();
    final next = f.nextStep();
    expect(next, isNotNull);
    expect(next!.kind, KotvFailoverKind.nextPlayer);
    expect(next.playerVal, 'innie#fvp');
    expect(next.decodeMode, 'auto');
  });

  test('drm lock gives up', () {
    final f = KotvPlaybackFailover(
      playerVal: 'innie#exo',
      decodeMode: 'auto',
      lockExoForDrm: true,
    );
    f.markAttempt();
    expect(f.nextStep(), isNull);
  });

  test('soft flips hard', () {
    final f = KotvPlaybackFailover(playerVal: 'innie#fvp', decodeMode: 'soft');
    f.markAttempt();
    final flip = f.nextStep();
    expect(flip!.kind, KotvFailoverKind.flipDecode);
    expect(flip.decodeMode, 'hard');
    final next = f.nextStep();
    expect(next!.playerVal, 'innie#mpv');
    expect(next.decodeMode, 'soft');
  });
}
