import 'package:flutter_test/flutter_test.dart';
import 'package:kotv/player/buffer_budget.dart';

void main() {
  test('fvpMaxBufferMs scales from memory budget', () {
    // 96MiB @ 4Mbps ≈ 201.3s
    final ms = KotvBufferBudget.fvpMaxBufferMs(96 * 1024 * 1024);
    expect(ms, greaterThan(1000));
    expect(ms, lessThanOrEqualTo(2 * 3600 * 1000));
    // tiny budget: proportional floor 1s (mdk API minimum)
    expect(KotvBufferBudget.fvpMaxBufferMs(1024), 1000);
  });

  test('mpvCacheProps uses bytes only', () {
    final props = KotvBufferBudget.mpvCacheProps(96 * 1024 * 1024);
    expect(props.containsKey('demuxer-max-bytes'), isTrue);
    expect(props.containsKey('cache-secs'), isFalse);
    expect(props.containsKey('demuxer-readahead-secs'), isFalse);
    expect(props['cache-pause-initial'], 'no');
  });

  test('mpvLiveCacheProps is empty (直播不写 demuxer-max-bytes/cache-secs)', () {
    final props = KotvBufferBudget.mpvLiveCacheProps();
    expect(props, isEmpty);
    expect(props.containsKey('demuxer-max-bytes'), isFalse);
    expect(props.containsKey('cache-secs'), isFalse);
  });
}
