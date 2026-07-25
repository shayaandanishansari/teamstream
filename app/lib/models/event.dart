/// A standalone calendar item. (Task deadlines come from Task.dueDate instead.)
class CalendarEvent {
  final String id;
  final String title;
  final DateTime date;
  final bool allDay;
  final String note;
  final String? taskId;

  const CalendarEvent({
    required this.id,
    required this.title,
    required this.date,
    this.allDay = true,
    this.note = '',
    this.taskId,
  });
}
