import 'package:flutter_test/flutter_test.dart';
import 'package:kotv/vod/list_style.dart';

void main() {
  test('list style comes from the site, the page, or an item', () {
    expect(kotvListStyle(), isFalse);
    expect(kotvListStyle(site: 'rect'), isFalse);
    expect(kotvListStyle(site: 'list'), isTrue);
    expect(kotvListStyle(page: 'List'), isTrue);
    expect(kotvListStyle(items: ['rect', 'list']), isTrue);
    expect(kotvNameInitial(''), '?');
    expect(kotvNameInitial('综合设置'), '综');
  });
}
