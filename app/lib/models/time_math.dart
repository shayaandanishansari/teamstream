import 'time_entry.dart';

/// Calendar arithmetic for the Dashboard's day/week/month windows.
///
/// Days are built with the DateTime(y, m, d ± n) constructor rather than by
/// adding a 24h Duration: across a DST boundary a "day" isn't 24 hours, and
/// arithmetic on Durations would silently drift the window off midnight.
DateTime startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);

DateTime nextDay(DateTime d) => DateTime(d.year, d.month, d.day + 1);

/// Monday-anchored, matching how DateTime.weekday numbers the week (Mon == 1).
DateTime startOfWeek(DateTime d) =>
    DateTime(d.year, d.month, d.day - (d.weekday - 1));

DateTime startOfMonth(DateTime d) => DateTime(d.year, d.month, 1);

/// How much of [e] lands inside `[from, to)`, with a live entry treated as
/// running up to [now].
///
/// Entries are sliced rather than assigned wholesale to their start day: a
/// timer left running overnight belongs partly to each day it crossed, and
/// bucketing it by start alone would credit tonight's hours to yesterday.
Duration overlapWithin(TimeEntry e, DateTime from, DateTime to, DateTime now) {
  final end = e.endedAt ?? now;
  final lo = e.startedAt.isAfter(from) ? e.startedAt : from;
  final hi = end.isBefore(to) ? end : to;
  final d = hi.difference(lo);
  return d.isNegative ? Duration.zero : d;
}
