import 'package:flutter_test/flutter_test.dart';
import 'package:kotv/player/mpv_opts.dart';
import 'package:kotv/player/video_eq.dart';

void main() {
  test('parseConfLines skips UI-managed options by default', () {
    final lines = KotvMpvOpts.parseConfLines('''
# comment
hwdec=no
vo=gpu
volume=50
cache-on-disk=yes
sub-font=Noto
''');
    expect(lines.map((e) => e.$1).toList(), ['volume', 'sub-font']);
  });

  test('findConfConflicts lists managed keys', () {
    final c = KotvMpvOpts.findConfConflicts('hwdec=no\nvolume=40\ncache=yes');
    expect(c, containsAll(['hwdec', 'cache']));
    expect(c, isNot(contains('volume')));
  });

  test('video eq presets', () {
    expect(KotvVideoEq.fromSettings({'videoEq': 'off'}).enabled, isFalse);
    final soft = KotvVideoEq.fromSettings({'videoEq': 'soft'});
    expect(soft.enabled, isTrue);
    expect(soft.mpvProps()['saturation'], isNot('0'));
    final natural = KotvVideoEq.fromSettings({'videoEq': 'natural'});
    expect(natural.enabled, isTrue);
    final cinema = KotvVideoEq.fromSettings({'videoEq': 'cinema'});
    expect(cinema.temperature, 26);
    final custom = KotvVideoEq.fromSettings({
      'videoEq': 'custom',
      'videoBrightness': '12',
    });
    expect(custom.brightness, 12);
  });

  test('audio dialogue strength and compose', () {
    expect(kotvAudioDialogueFromSettings({'audioDialogue': 'true'}), 100);
    expect(kotvAudioDialogueFromSettings({'audioDialogue': '40'}), 40);
    expect(kotvAudioDialogueFromSettings({'audioDialogue': 'false'}), 0);
    final af = kotvComposeMpvAf(
      eq: KotvAudioEqPreset.bass,
      dialogue: 50,
      balance: -20,
      stability: 30,
      boost: 200,
    );
    expect(af, contains('lavfi=['));
    expect(af, contains('equalizer'));
    expect(af, contains('pan=stereo'));
  });
}
