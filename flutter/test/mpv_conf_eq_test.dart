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
    final custom = KotvVideoEq.fromSettings({
      'videoEq': 'custom',
      'videoBrightness': '12',
    });
    expect(custom.brightness, 12);
  });
}
