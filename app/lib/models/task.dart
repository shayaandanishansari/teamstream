/// Marks "argument not supplied" in [Task.copyWith], so that passing an
/// explicit null (clearing a due date) is distinguishable from omitting it.
const Object _keep = Object();

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

  Task copyWith({
    String? title,
    bool? isDone,
    Object? doneAt = _keep,
    bool? isArchived,
    String? note,
    Object? dueDate = _keep,
    bool? critical,
    double? position,
  }) =>
      Task(
        id: id,
        workId: workId,
        title: title ?? this.title,
        isDone: isDone ?? this.isDone,
        doneAt: identical(doneAt, _keep) ? this.doneAt : doneAt as DateTime?,
        isArchived: isArchived ?? this.isArchived,
        note: note ?? this.note,
        dueDate: identical(dueDate, _keep) ? this.dueDate : dueDate as DateTime?,
        critical: critical ?? this.critical,
        position: position ?? this.position,
      );
}
