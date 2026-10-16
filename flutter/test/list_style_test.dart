import 'package:flutter_test/flutter_test.dart';
import 'package:kotv/vod/list_style.dart';

void main() {
  test('name initial is the first character', () {
    expect(kotvNameInitial(''), '?');
    expect(kotvNameInitial('综合设置'), '综');
  });
}
