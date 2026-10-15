import 'package:flutter_test/flutter_test.dart';
import 'package:kotv/models/models.dart';
import 'package:kotv/remote/remote_bridge.dart';

void main() {
  test('LocalHistory.toSyncTargets builds history JSON', () {
    final targets = LocalHistory.toSyncTargets([
      VodItem(
        id: 'v1',
        name: '剧',
        site: 's1',
        remarks: '第1集',
        flag: '线',
        positionMs: 123456,
        durationMs: 600000,
      ),
    ]);
    expect(targets, hasLength(1));
    expect(targets.first['key'], 's1\$\$\$v1');
    expect(targets.first['position'], 123456);
    expect(targets.first['vodFlag'], '线');
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
}
