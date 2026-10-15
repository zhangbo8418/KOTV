import 'package:flutter_test/flutter_test.dart';
import 'package:kotv/models/models.dart';
import 'package:kotv/remote/local_collect.dart';

void main() {
  test('LocalCollect.toSyncTargets builds keep JSON', () {
    final targets = LocalCollect.toSyncTargets([
      VodItem(id: '1', name: '片', pic: 'p', site: 's', remarks: 'r', flag: 'f'),
    ]);
    expect(targets, hasLength(1));
    expect(targets.first['key'], 's\$\$\$1');
    expect(targets.first['vodName'], '片');
  });

  test('LocalCollect.fromSyncTargets restores siteName as configSource', () {
    final items = LocalCollect.fromSyncTargets(
      '[{"key":"s\$\$\$1","vodName":"片","siteName":"http://cfg"}]',
    );
    expect(items, hasLength(1));
    expect(items.first.id, '1');
    expect(items.first.site, 's');
    expect(items.first.configSource, 'http://cfg');
  });

  test('LocalCollect.fromSyncTargets restores config_source', () {
    final items = LocalCollect.fromSyncTargets(
      '[{"key":"s\$\$\$1","vodName":"片","config_source":"http://cfg"}]',
    );
    expect(items, hasLength(1));
    expect(items.first.configSource, 'http://cfg');
  });
}
