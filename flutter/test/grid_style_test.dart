import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kotv/theme/kotv_theme.dart';
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
    // 1080p 逻辑约 960×540，4K/8K 逻辑可到 1920×1080 或更大；电视列数不跟短边走。
    expect(
      kotvPosterColumns(
          width: 960, height: 540, size: 2, landStyle: false, television: true),
      5,
    );
    expect(
      kotvPosterColumns(
          width: 1920,
          height: 1080,
          size: 2,
          landStyle: false,
          television: true),
      5,
    );
    expect(
      kotvPosterColumns(
          width: 3840,
          height: 2160,
          size: 2,
          landStyle: false,
          television: true),
      5,
    );
    expect(
      kotvPosterColumns(
          width: 1920, height: 1080, size: 2, landStyle: true, television: true),
      4,
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

  test('title strip is one text line plus its padding', () {
    final line = kotvPosterNameLineHeight(television: false);
    expect(kotvPosterNameFont(television: false), 14);
    expect(kotvPosterTitleExtent(television: false), line + kotvPosterNamePad * 2);
    final tvLine = kotvPosterNameLineHeight(television: true);
    expect(kotvPosterNameFont(television: true), 16);
    expect(kotvPosterTitleExtent(television: true), tvLine + kotvPosterNamePad * 2);
    final style = kotvPosterNameStyle(television: false);
    expect(style.inherit, isTrue);
    expect(style.fontWeight, FontWeight.w700);
    expect(style.height, 1.15);
    expect(style.fontFamily, kotvThemeFontFamily());
    expect(style.fontFamilyFallback, kotvFontFallbacks());
  });

  test('cell aspect matches the image ratio', () {
    expect(kotvPosterCellAspect(ratio: 0.75), 0.75);
    expect(kotvPosterCellAspect(ratio: 1.33), 1.33);
    expect(kotvPosterCellAspect(ratio: 0, oval: true), 1);
    expect(kotvPosterCellAspect(ratio: 9), 4);
  });
}
