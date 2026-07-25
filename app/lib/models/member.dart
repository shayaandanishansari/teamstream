/// One of the (three) people. Pure data — no backend coupling.
class Member {
  final String id;
  final String name;
  final String color; // hex, e.g. #00A896

  const Member({required this.id, required this.name, required this.color});
}
