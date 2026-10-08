import 'package:flutter_test/flutter_test.dart';
import 'package:kotv/search/suggest_words.dart';
import 'package:kotv/search/zhu_to_pin.dart';

void main() {
  test('suggest titles prefer title then name', () {
    expect(
      parseSuggestTitles('{"data":[{"title":"开心锤锤"},{"name":"王心凌"}]}'),
      ['开心锤锤', '王心凌'],
    );
    expect(parseSuggestTitles('{"data":[{"title":"甲","name":"乙"}]}'), ['甲']);
    expect(parseSuggestTitles('not json'), isEmpty);
  });

  test('zhuyin converts by the longest match', () {
    expect(zhuToPin(''), '');
    expect(zhuToPin('ㄅ'), 'b');
    expect(zhuToPin('ㄩㄥ'), 'yong');
    expect(zhuToPin('ㄓㄨ'), 'zhu');
    expect(zhuToPin('ABC'), 'ABC');
    expect(zhuToPin('ㄅx'), 'bx');
  });
}
