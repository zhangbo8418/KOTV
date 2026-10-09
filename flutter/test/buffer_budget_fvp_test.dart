import 'package:flutter_test/flutter_test.dart';
import 'package:kotv/player/buffer_budget.dart';

void main() {
  test('fvpMaxBufferMs follows memory budget and stream bitrate', () {
    const budget = 96 * 1024 * 1024;
    final sd = KotvBufferBudget.fvpMaxBufferMs(budget, bitsPerSec: 4 * 1000 * 1000);
    final uhd = KotvBufferBudget.fvpMaxBufferMs(budget, bitsPerSec: 40 * 1000 * 1000);
    expect(sd, greaterThan(uhd));
    expect(sd / uhd, closeTo(10, 0.05));
    expect(sd, lessThanOrEqualTo(2 * 3600 * 1000));
    expect(KotvBufferBudget.fvpMaxBufferMs(budget, bitsPerSec: 0), 0);
    expect(KotvBufferBudget.fvpMaxBufferMs(0, bitsPerSec: 4 * 1000 * 1000), 0);
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
