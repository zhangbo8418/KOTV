import 'package:flutter_test/flutter_test.dart';
import 'package:kotv/models/models.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kotv/remote/remote_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('LocalHistory stores and restores vod_flag', () async {
    await LocalHistory.push(VodItem(
      id: 'v1',
      name: '剧',
      site: 's1',
      remarks: '第2集',
      flag: '线路B',
    ));
    final list = await LocalHistory.list();
    expect(list, hasLength(1));
    expect(list.first.flag, '线路B');
    expect(list.first.remarks, '第2集');
  });

  test('LocalHistory.replaceId migrates key', () async {
    await LocalHistory.push(VodItem(
      id: 'route-id',
      name: '剧',
      site: 's1',
      remarks: '第3集',
      flag: '线路A',
    ));
    await LocalHistory.replaceId(site: 's1', oldId: 'route-id', newId: 'real-id');
    final list = await LocalHistory.list();
    expect(list, hasLength(1));
    expect(list.first.id, 'real-id');
    expect(list.first.remarks, '第3集');
    expect(list.first.flag, '线路A');
  });

  test('LocalHistory persists position for resume', () async {
    await LocalHistory.push(VodItem(
      id: 'v1',
      name: '剧',
      site: 's1',
      remarks: '第1集',
      flag: '线',
      positionMs: 123456,
      durationMs: 600000,
    ));
    final list = await LocalHistory.list();
    expect(list.first.positionMs, 123456);
    expect(list.first.durationMs, 600000);
    final targets = LocalHistory.toSyncTargets(list);
    expect(targets.first['position'], 123456);
    expect(targets.first['key'], 's1\$\$\$v1');
  });

  test('LocalHistory.fromSyncTargets parses site\$\$\$id', () {
    final items = LocalHistory.fromSyncTargets(
      '[{"key":"s1\$\$\$v9","vodName":"N","vodPic":"p","vodFlag":"f","vodRemarks":"ep1","position":9000,"duration":10000}]',
    );
    expect(items, hasLength(1));
    expect(items.first.id, 'v9');
    expect(items.first.site, 's1');
    expect(items.first.positionMs, 9000);
    expect(items.first.flag, 'f');
  });

  test('LocalRevSort persists', () async {
    expect(await LocalRevSort.get('v1', 's1'), isFalse);
    await LocalRevSort.set('v1', 's1', true);
    expect(await LocalRevSort.get('v1', 's1'), isTrue);
  });
}
