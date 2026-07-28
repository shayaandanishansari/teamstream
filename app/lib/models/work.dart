/// A project. Its state + board order are DERIVED from its child tasks,
/// never set by hand.
class Work {
  final String id;
  final String title;
  final double position;
  final bool archived;

  const Work({
    required this.id,
    required this.title,
    this.position = 0,
    this.archived = false,
  });

  Work copyWith({String? title, double? position, bool? archived}) => Work(
        id: id,
        title: title ?? this.title,
        position: position ?? this.position,
        archived: archived ?? this.archived,
      );
}
