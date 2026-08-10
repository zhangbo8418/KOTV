import 'package:flutter_test/flutter_test.dart';
import 'package:kotv/player/buffer_budget.dart';

void main() {
  test('fvpMaxBufferMs scales from memory budget', () {
    // 96MiB @ 4Mbps ≈ 201.3s → clamp >= 60s
    final ms = KotvBufferBudget.fvpMaxBufferMs(96 * 1024 * 1024);
    expect(ms, greaterThanOrEqualTo(60 * 1000));
    expect(ms, lessThanOrEqualTo(2 * 3600 * 1000));
    // tiny budget still at least 1 min
    expect(KotvBufferBudget.fvpMaxBufferMs(1024), 60 * 1000);
  });
}
