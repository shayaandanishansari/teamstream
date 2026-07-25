/// The core mechanism. One press = one entry. ended_at == null means LIVE now.
/// Multiple concurrent entries per person are allowed (they overlap).
class TimeEntry {
  final String id;
  final String taskId;
  final String memberId;
  final DateTime startedAt;
  final DateTime? endedAt;

  const TimeEntry({
    required this.id,
    required this.taskId,
    required this.memberId,
    required this.startedAt,
    this.endedAt,
  });

  bool get isLive => endedAt == null;

  Duration durationAsOf(DateTime now) => (endedAt ?? now).difference(startedAt);
}
