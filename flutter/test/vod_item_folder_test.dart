import 'package:flutter_test/flutter_test.dart';
import 'package:kotv/models/models.dart';

void main() {
  test('VodItem.isFolder matches engine: folder tag or cate', () {
    expect(VodItem(id: '1', name: 'a', vodTag: 'folder').isFolder, isTrue);
    expect(VodItem(id: '1', name: 'a', vodTag: 'FOLDER').isFolder, isTrue);
    expect(VodItem(id: '1', name: 'a', vodTag: 'file').isFolder, isFalse);
    expect(VodItem(id: '1', name: 'a', vodTag: 'file', cate: '{"land":1}').isFolder, isTrue);
    expect(VodItem(id: '1', name: 'a', cate: '{"land":1}').isFolder, isTrue);
    expect(VodItem(id: '1', name: 'a').isFolder, isFalse);
  });
}
