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

  test('fromDevice follows available memory and does not clamp to a fixed size', () {
    const gb = 1024 * 1024 * 1024;
    final tight = KotvBufferBudget.fromDevice(
      totalBytes: 8 * gb,
      availBytes: 2 * gb,
      desktop: true,
    );
    expect(tight, (2 * gb * 0.15).round());
    final roomy = KotvBufferBudget.fromDevice(
      totalBytes: 64 * gb,
      availBytes: 32 * gb,
      desktop: true,
    );
    expect(roomy, (64 * gb * 0.05).round());
    expect(roomy, greaterThan(384 * 1024 * 1024));
    final noAvail = KotvBufferBudget.fromDevice(
      totalBytes: 8 * gb,
      availBytes: 0,
      desktop: false,
    );
    expect(noAvail, (8 * gb * 0.05).round());
  });

  test('bitsPerSecFromQueue is bytes over duration', () {
    expect(KotvBufferBudget.bitsPerSecFromQueue(0, 1000), 0);
    expect(KotvBufferBudget.bitsPerSecFromQueue(500000, 0), 0);
    expect(KotvBufferBudget.bitsPerSecFromQueue(500000, 1000), 4 * 1000 * 1000);
    final budget = 96 * 1024 * 1024;
    final bps = KotvBufferBudget.bitsPerSecFromQueue(500000, 1000);
    final slow = KotvBufferBudget.bitsPerSecFromQueue(50000, 1000);
    expect(
      KotvBufferBudget.fvpMaxBufferMs(budget, bitsPerSec: slow),
      greaterThan(KotvBufferBudget.fvpMaxBufferMs(budget, bitsPerSec: bps)),
    );
  });

  test('mpvMiB keeps the budget proportion', () {
    expect(KotvBufferBudget.mpvMiB(96 * 1024 * 1024), '96MiB');
    expect(KotvBufferBudget.mpvMiB(5 * 1024 * 1024 * 1024), '5120MiB');
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
