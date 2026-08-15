import 'package:flutter_test/flutter_test.dart';
import 'package:kotv/widgets/config_branding.dart';

void main() {
  test('parse tencent banner map', () {
    const body = '''
{
  "mzc002000iis17y": {
    "id": "mzc002000iis17y",
    "title": "斩神2·结局点映",
    "image": "https://tv.puui.qpic.cn/a.jpg",
    "msg": "ok",
    "notes": "Tencent Video PC 轮播图"
  },
  "mzc002003kpyd2m": {
    "id": "mzc002003kpyd2m",
    "title": "心动的信号9",
    "image": "https://tv.puui.qpic.cn/b.jpg",
    "msg": "ok"
  }
}
''';
    final slides = parseConfigBannerJson(body);
    expect(slides.length, 2);
    expect(slides.any((e) => e.title == '斩神2·结局点映' && e.image.contains('a.jpg')), isTrue);
    expect(slides.any((e) => e.id == 'mzc002003kpyd2m'), isTrue);
  });
}
