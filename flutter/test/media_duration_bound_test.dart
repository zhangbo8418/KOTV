import 'package:flutter_test/flutter_test.dart';
import 'package:kotv/widgets/vod_player_chrome.dart';

void main() {
  test('FVP live duration is not added onto the clock', () {
    const live = Duration(microseconds: unboundedMediaDurationUs);
    expect(boundedMediaDuration(live), isFalse);
    expect(unboundedMediaDuration(live), isTrue);
    expect(fmtBoundedClock(live), '--:--:--');
    expect(fmtBoundedPlayerTime(live), '--:--');
    expect(fmtBoundedClock(Duration.zero), '00:00:00');
    expect(fmtBoundedPlayerTime(const Duration(seconds: 14)), '00:14');
    expect(() => DateTime.now().add(live), throwsRangeError);
    expect(sliderMaxMs(live, const Duration(seconds: 12)), 12000);
    expect(sliderMaxMs(const Duration(seconds: 90), Duration.zero), 90000);
  });
}
