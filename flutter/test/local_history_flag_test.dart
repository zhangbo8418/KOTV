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
}
