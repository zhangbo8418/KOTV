import 'package:flutter_test/flutter_test.dart';
import 'package:kotv/vod/content_clicker.dart';

void main() {
  test('parseKotvContentClick reads type_id and type_name', () {
    final c = parseKotvContentClick(
      '{"type_id":"tid1","type_name":"电影"}',
      '点我',
    );
    expect(c, isNotNull);
    expect(c!.typeId, 'tid1');
    expect(c.typeName, '电影');
    expect(c.label, '点我');
  });

  test('parseKotvContentClick accepts id/name aliases', () {
    final c = parseKotvContentClick('{"id":"x","name":"剧"}', '');
    expect(c, isNotNull);
    expect(c!.typeId, 'x');
    expect(c.typeName, '剧');
    expect(c.label, '剧');
  });

  test('kotvContentClicker matches Sniffer.CLICKER shape', () {
    const raw = '前缀[a=cr:{"type_id":"1","type_name":"A"}/]点这里[/a]后缀';
    final m = kotvContentClicker.firstMatch(raw);
    expect(m, isNotNull);
    expect(m!.group(1), contains('type_id'));
    expect(m.group(2), '点这里');
  });

  test('parseKotvContentClick rejects empty type id', () {
    expect(parseKotvContentClick('{"type_name":"A"}', 'x'), isNull);
    expect(parseKotvContentClick('not-json', 'x'), isNull);
  });
}
