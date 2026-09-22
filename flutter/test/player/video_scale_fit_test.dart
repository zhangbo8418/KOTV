import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kotv/player/video_scale_fit.dart';

void main() {
  test('kotvFitFromVideoScale maps modes', () {
    expect(kotvFitFromVideoScale('default', BoxFit.cover), BoxFit.contain);
    expect(kotvFitFromVideoScale('FILL', BoxFit.contain), BoxFit.fill);
    expect(kotvFitFromVideoScale('16:9', BoxFit.contain), BoxFit.contain);
    expect(kotvFitFromVideoScale('4:3', BoxFit.contain), BoxFit.contain);
    expect(kotvFitFromVideoScale('zoom', BoxFit.contain), BoxFit.cover);
    expect(kotvFitFromVideoScale('unknown', BoxFit.cover), BoxFit.cover);
  });

  test('kotvBoxForVideoScale forces 16:9 letterbox', () {
    final box = kotvBoxForVideoScale(const Size(1920, 1080), const Size(640, 480), '16:9');
    expect(box.width / box.height, closeTo(16 / 9, 0.001));
    expect(box.width, lessThanOrEqualTo(1920));
    expect(box.height, lessThanOrEqualTo(1080));
  });
}
