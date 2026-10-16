import 'package:flutter_test/flutter_test.dart';
import 'package:kotv/vod/grid_style.dart';

void main() {
  test('poster columns follow orientation, pad and size', () {
    expect(
      kotvPosterColumns(width: 400, height: 800, size: 2, landStyle: false),
      3,
    );
    expect(
      kotvPosterColumns(width: 800, height: 400, size: 2, landStyle: false),
      5,
    );
    expect(
      kotvPosterColumns(width: 800, height: 1200, size: 2, landStyle: false),
      4,
    );
    expect(
      kotvPosterColumns(width: 400, height: 800, size: 3, landStyle: false),
      2,
    );
    expect(
      kotvPosterColumns(width: 400, height: 800, size: 2, landStyle: true),
      2,
    );
  });

  test('style ratio is capped and defaults by type', () {
    expect(KotvGridStyle.parse({'type': 'rect', 'ratio': 1.33}).isLand, isTrue);
    expect(KotvGridStyle.parse({'type': 'rect', 'ratio': 9}).ratio, 4);
    expect(KotvGridStyle.parse({'type': 'oval'}).ratio, 1);
    expect(KotvGridStyle.parse({'type': 'rect'}).ratio, 0.75);
    expect(kotvPosterSizeValue(''), 2);
    expect(kotvPosterSizeValue('3'), 3);
  });

  test('cell aspect is image height plus title', () {
    final aspect = kotvPosterCellAspect(
      extent: 300,
      columns: 3,
      gap: 0,
      ratio: 1,
      titleHeight: 36,
    );
    expect(aspect, closeTo(100 / 136, 0.001));
  });
}
