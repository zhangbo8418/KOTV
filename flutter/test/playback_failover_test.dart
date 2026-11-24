import 'package:flutter_test/flutter_test.dart';

import 'package:kotv/player/playback_failover.dart';

void main() {
  test('hard falls back to soft then next player restores settings decode', () {
    final f = KotvPlaybackFailover(playerVal: 'innie#fvp', decodeMode: 'hard');
    f.markAttempt();
    final soft = f.nextStep();
    expect(soft, isNotNull);
    expect(soft!.kind, KotvFailoverKind.softDecode);
    expect(soft.decodeMode, 'soft');
    expect(f.decodeMode, 'soft');

    final next = f.nextStep();
    expect(next, isNotNull);
    expect(next!.kind, KotvFailoverKind.nextPlayer);
    expect(next.playerVal, 'innie#mpv');
    expect(next.decodeMode, 'hard');
  });

  test('mpv hard falls back to soft like other engines', () {
    final f = KotvPlaybackFailover(playerVal: 'innie#mpv', decodeMode: 'hard');
    f.markAttempt();
    final step = f.nextStep();
    expect(step, isNotNull);
    expect(step!.kind, KotvFailoverKind.softDecode);
    expect(step.decodeMode, 'soft');
    expect(f.decodeMode, 'soft');
  });

  test('auto falls back to soft then next player', () {
    final f = KotvPlaybackFailover(playerVal: 'innie#mpv', decodeMode: 'auto');
    f.markAttempt();
    final soft = f.nextStep();
    expect(soft, isNotNull);
    expect(soft!.kind, KotvFailoverKind.softDecode);
    expect(soft.decodeMode, 'soft');
    expect(f.decodeMode, 'soft');

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

  test('soft goes straight to the next player', () {
    final f = KotvPlaybackFailover(playerVal: 'innie#fvp', decodeMode: 'soft');
    f.markAttempt();
    final next = f.nextStep();
    expect(next!.playerVal, 'innie#mpv');
    expect(next.decodeMode, 'soft');
  });

  test('session soft keeps settings decode when switching player', () {
    final f = KotvPlaybackFailover(
      playerVal: 'innie#mpv',
      decodeMode: 'soft',
      settingsDecodeMode: 'auto',
    );
    f.markAttempt();
    final next = f.nextStep();
    expect(next, isNotNull);
    expect(next!.kind, KotvFailoverKind.nextPlayer);
    expect(next.decodeMode, 'auto');
    expect(f.decodeMode, 'auto');
  });

  test('disabled failover gives up', () {
    final f = KotvPlaybackFailover(
      playerVal: 'innie#mpv',
      decodeMode: 'hard',
      enabled: false,
    );
    f.markAttempt();
    expect(f.nextStep(), isNull);
  });

  test('enabledFromSetting', () {
    expect(KotvPlaybackFailover.enabledFromSetting('auto'), isTrue);
    expect(KotvPlaybackFailover.enabledFromSetting(''), isTrue);
    expect(KotvPlaybackFailover.enabledFromSetting('off'), isFalse);
    expect(KotvPlaybackFailover.enabledFromSetting('false'), isFalse);
  });

  test('off does not flip decode or change player', () {
    final f = KotvPlaybackFailover(
      playerVal: 'innie#mpv',
      decodeMode: 'hard',
      enabled: false,
    );
    f.markAttempt();
    expect(f.nextStep(), isNull);
    expect(f.playerVal, 'innie#mpv');
    expect(f.decodeMode, 'hard');
  });

  test('plan: off keeps session', () {
    final f = KotvPlaybackFailover(
      playerVal: 'innie#fvp',
      decodeMode: 'auto',
      enabled: false,
    );
    f.markAttempt();
    final plan = kotvPlanSilentRecover(failover: f);
    expect(plan.action, KotvSilentRecoverAction.keepSession);
  });

  test('plan: on + auto applies soft decode step', () {
    final f = KotvPlaybackFailover(playerVal: 'innie#mpv', decodeMode: 'auto');
    f.markAttempt();
    final plan = kotvPlanSilentRecover(failover: f);
    expect(plan.action, KotvSilentRecoverAction.applyStep);
    expect(plan.step!.decodeMode, 'soft');
    expect(plan.step!.playerVal, 'innie#mpv');
    expect(f.playerVal, 'innie#mpv');
  });

  test('plan: on + exhausted ring gives up', () {
    final f = KotvPlaybackFailover(playerVal: 'innie#fvp', decodeMode: 'auto');
    f.markAttempt();
    while (true) {
      final s = f.nextStep();
      if (s == null) break;
      f.markAttempt();
    }
    final plan = kotvPlanSilentRecover(failover: f);
    expect(plan.action, KotvSilentRecoverAction.giveUp);
  });
}
