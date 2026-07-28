import 'package:flutter_test/flutter_test.dart';
import 'package:teamstream/models/time_entry.dart';
import 'package:teamstream/models/time_math.dart';

TimeEntry entry(DateTime start, DateTime? end) =>
    TimeEntry(id: 'e', taskId: 't', memberId: 'm', startedAt: start, endedAt: end);

void main() {
  final now = DateTime(2026, 7, 28, 14, 30); // Tuesday

  group('window edges', () {
    test('startOfWeek anchors on Monday', () {
      expect(startOfWeek(now), DateTime(2026, 7, 27));
      expect(startOfWeek(DateTime(2026, 7, 27, 0, 1)), DateTime(2026, 7, 27));
      expect(startOfWeek(DateTime(2026, 8, 2, 23, 59)), DateTime(2026, 7, 27));
    });

    test('nextDay rolls over month ends', () {
      expect(nextDay(DateTime(2026, 7, 31, 9)), DateTime(2026, 8, 1));
    });
  });

  group('overlapWithin', () {
    final from = startOfDay(now);
    final to = nextDay(now);

    test('counts an entry wholly inside the window', () {
      final e = entry(DateTime(2026, 7, 28, 9), DateTime(2026, 7, 28, 10, 30));
      expect(overlapWithin(e, from, to, now), const Duration(minutes: 90));
    });

    test('ignores an entry outside the window', () {
      final e = entry(DateTime(2026, 7, 27, 9), DateTime(2026, 7, 27, 17));
      expect(overlapWithin(e, from, to, now), Duration.zero);
    });

    test('clips an overnight entry to the part that falls in the day', () {
      // Started 22:00 yesterday, stopped 02:00 today -> 2h belongs to today.
      final e = entry(DateTime(2026, 7, 27, 22), DateTime(2026, 7, 28, 2));
      expect(overlapWithin(e, from, to, now), const Duration(hours: 2));
      // ...and the other 2h belongs to yesterday.
      expect(
        overlapWithin(e, DateTime(2026, 7, 27), DateTime(2026, 7, 28), now),
        const Duration(hours: 2),
      );
    });

    test('runs a live entry up to now, not to the end of the window', () {
      final e = entry(DateTime(2026, 7, 28, 13), null);
      expect(overlapWithin(e, from, to, now), const Duration(minutes: 90));
    });

    test('a live entry started yesterday splits across both days', () {
      final e = entry(DateTime(2026, 7, 27, 23), null);
      expect(overlapWithin(e, from, to, now), const Duration(hours: 14, minutes: 30));
      expect(
        overlapWithin(e, DateTime(2026, 7, 27), DateTime(2026, 7, 28), now),
        const Duration(hours: 1),
      );
    });
  });

  test('LogPeriod ranges cover the expected span', () {
    // Sanity on the day/week/month anchors the log filter relies on.
    expect(startOfMonth(now), DateTime(2026, 7, 1));
    expect(startOfDay(now), DateTime(2026, 7, 28));
  });
}
