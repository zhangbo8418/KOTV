import 'package:flutter_test/flutter_test.dart';
import 'package:kotv/models/models.dart';
import 'package:kotv/remote/local_collect.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('LocalCollect persists vod_tag cate action folder fields', () async {
    await LocalCollect.toggle(VodItem(
      id: 'f1',
      name: '目录',
      site: 's1',
      vodTag: 'folder',
      cate: '{"land":1}',
      action: '',
      folder: true,
    ));
    final list = await LocalCollect.list();
    expect(list, hasLength(1));
    expect(list.first.isFolder, isTrue);
    expect(list.first.vodTag, 'folder');
    expect(list.first.cate, contains('land'));
  });
}
