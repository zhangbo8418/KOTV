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

  test('LocalCollect.replaceId migrates key and drops duplicate', () async {
    await LocalCollect.toggle(VodItem(id: 'old', name: '旧', pic: 'p0', site: 's1'));
    await LocalCollect.replaceId(site: 's1', oldId: 'old', newId: 'new');
    var list = await LocalCollect.list();
    expect(list, hasLength(1));
    expect(list.first.id, 'new');
    expect(list.first.name, '旧');

    await LocalCollect.toggle(VodItem(id: 'dup-old', name: 'A', site: 's1'));
    await LocalCollect.toggle(VodItem(id: 'dup-new', name: 'B', site: 's1'));
    await LocalCollect.replaceId(site: 's1', oldId: 'dup-old', newId: 'dup-new');
    list = await LocalCollect.list();
    expect(list.where((e) => e.site == 's1' && (e.id == 'dup-old' || e.id == 'dup-new')), hasLength(1));
    expect(list.any((e) => e.id == 'dup-old'), isFalse);
    expect(list.any((e) => e.id == 'dup-new'), isTrue);
  });

  test('LocalCollect.updateMeta refreshes name and pic', () async {
    await LocalCollect.toggle(VodItem(id: 'v1', name: '旧名', pic: 'old.png', site: 's1', remarks: 'r0'));
    await LocalCollect.updateMeta(id: 'v1', site: 's1', name: '新名', pic: 'new.png', remarks: 'r1', typeName: '电影');
    final list = await LocalCollect.list();
    expect(list, hasLength(1));
    expect(list.first.name, '新名');
    expect(list.first.pic, 'new.png');
    expect(list.first.remarks, 'r1');
    expect(list.first.typeName, '电影');
  });

  test('LocalCollect configSource separates keys', () async {
    await LocalCollect.toggle(VodItem(id: 'v1', name: 'A', site: 's1', configSource: 'http://a'));
    await LocalCollect.toggle(VodItem(id: 'v1', name: 'B', site: 's1', configSource: 'http://b'));
    final list = await LocalCollect.list();
    expect(list.where((e) => e.id == 'v1' && e.site == 's1'), hasLength(2));
    expect(await LocalCollect.isKept('v1', 's1', configSource: 'http://a'), isTrue);
    expect(await LocalCollect.isKept('v1', 's1', configSource: 'http://b'), isTrue);
  });

  test('LocalCollect.toSyncTargets builds keep JSON', () {
    final targets = LocalCollect.toSyncTargets([
      VodItem(id: '1', name: '片', pic: 'p', site: 's', remarks: 'r', flag: 'f'),
    ]);
    expect(targets, hasLength(1));
    expect(targets.first['key'], 's\$\$\$1');
    expect(targets.first['vodName'], '片');
  });
}
