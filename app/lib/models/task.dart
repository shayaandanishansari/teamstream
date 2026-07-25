/// The durable unit. People flow through it via time_entries.
class Task {
  final String id;
  final String workId;
  final String title;
  final bool isDone;
  final DateTime? doneAt;
  final bool isArchived;
  final String note;
  final DateTime? dueDate;
  final bool critical;
  final double position;

  const Task({
    required this.id,
    required this.workId,
    required this.title,
    this.isDone = false,
    this.doneAt,
    this.isArchived = false,
    this.note = '',
    this.dueDate,
    this.critical = false,
    this.position = 0,
  });
}
