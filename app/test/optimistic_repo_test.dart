import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:teamstream/data/optimistic_repo.dart';
import 'package:teamstream/data/team_stream_repo.dart';
import 'package:teamstream/models/attachment.dart';
import 'package:teamstream/models/event.dart';
import 'package:teamstream/models/member.dart';
import 'package:teamstream/models/task.dart';
import 'package:teamstream/models/time_entry.dart';
import 'package:teamstream/models/work.dart';

/// A stand-in backend whose writes we hold open by hand, so we can inspect the
/// UI's view of the world *while* a write is still in the air.
class FakeRepo implements TeamStreamRepo {
  final entries = StreamController<List<TimeEntry>>.broadcast();
  final tasks = StreamController<List<Task>>.broadcast();
  final works = StreamController<List<Work>>.broadcast();
  final events = StreamController<List<CalendarEvent>>.broadcast();
  final attachments = StreamController<List<Attachment>>.broadcast();

  /// Completes the next write. Tests resolve or reject it explicitly.
  Completer<void>? gate;
  int toggleCalls = 0;

  Future<void> _gated() {
    gate = Completer<void>();
    return gate!.future;
  }

  @override
  Stream<List<TimeEntry>> watchTimeEntries() => entries.stream;
  @override
  Stream<List<Task>> watchTasks() => tasks.stream;
  @override
  Stream<List<Work>> watchWorks() => works.stream;
  @override
  Stream<List<CalendarEvent>> watchEvents() => events.stream;
  @override
  Stream<List<Attachment>> watchAttachments() => attachments.stream;

  @override
  Future<Attachment> addAttachment({
    required String taskId,
    required String memberId,
    required String filename,
    required Uint8List bytes,
  }) async {
    await _gated();
    return Attachment(
      id: 'server-file',
      taskId: taskId,
      memberId: memberId,
      name: filename,
      url: 'https://example.test/$filename',
      size: bytes.length,
      created: DateTime.now(),
    );
  }

  @override
  Future<void> deleteAttachment(String attachmentId) => _gated();

  @override
  Future<void> toggleTimer({required String taskId, required String memberId}) {
    toggleCalls++;
    return _gated();
  }

  @override
  Future<void> setTaskDone(String taskId, bool done) => _gated();

  @override
  Future<void> renameWork(String workId, String title) => _gated();

  @override
  Future<void> renameTask(String taskId, String title) => _gated();

  @override
  Future<void> deleteTask(String taskId) => _gated();

  // ---- unused by these tests ----
  @override
  Future<List<Member>> fetchMembers() async => [];
  @override
  Future<Member> authenticate(String name, String password) async =>
      const Member(id: 'm', name: 'm', color: '#000000');
  @override
  bool get isAuthenticated => true;
  @override
  Member? get currentMember => null;
  @override
  void signOut() {}
  @override
  void setActor(String memberId, String memberName) {}
  @override
  Future<Work> createWork(String title) async => Work(id: 'w', title: title);
  @override
  Future<Task> createTask({required String workId, required String title}) async =>
      Task(id: 't', workId: workId, title: title);
  @override
  Future<void> deleteWork(String workId) => _gated();
  @override
  Future<void> setTaskArchived(String taskId, bool archived) => _gated();
  @override
  Future<void> updateTaskNote(String taskId, String note) => _gated();
  @override
  Future<void> setTaskDueDate(String taskId, DateTime? due) => _gated();
  @override
  Future<void> setTaskCritical(String taskId, bool critical) => _gated();
  @override
  Future<CalendarEvent> createEvent({
    required String title,
    required DateTime date,
    bool allDay = false,
    String note = '',
  }) async =>
      CalendarEvent(id: 'e', title: title, date: date);
  @override
  void dispose() {}
}

void main() {
  late FakeRepo fake;
  late OptimisticRepo repo;
  late List<List<TimeEntry>> seenEntries;
  late List<List<Task>> seenTasks;
  late List<List<Attachment>> seenFiles;

  setUp(() {
    fake = FakeRepo();
    repo = OptimisticRepo(fake);
    seenEntries = [];
    seenTasks = [];
    seenFiles = [];
    repo.watchTimeEntries().listen(seenEntries.add);
    repo.watchTasks().listen(seenTasks.add);
    repo.watchAttachments().listen(seenFiles.add);
  });

  final someBytes = Uint8List.fromList([1, 2, 3, 4]);

  /// Lets pending microtasks and stream events settle.
  Future<void> pump() => Future<void>.delayed(Duration.zero);

  test('starting a timer shows up before the server replies', () async {
    fake.entries.add(const []);
    await pump();

    unawaited(repo.toggleTimer(taskId: 'task1', memberId: 'me'));
    await pump();

    // The write is still in the air...
    expect(fake.gate!.isCompleted, isFalse);
    // ...but the UI already sees a live entry.
    expect(seenEntries.last, hasLength(1));
    expect(seenEntries.last.single.isLive, isTrue);
    expect(seenEntries.last.single.taskId, 'task1');
  });

  test('stopping a timer closes it before the server replies', () async {
    final live = TimeEntry(
      id: 'e1',
      taskId: 'task1',
      memberId: 'me',
      startedAt: DateTime.now().subtract(const Duration(minutes: 5)),
    );
    fake.entries.add([live]);
    await pump();

    unawaited(repo.toggleTimer(taskId: 'task1', memberId: 'me'));
    await pump();

    expect(seenEntries.last.single.isLive, isFalse,
        reason: 'the stop should be visible immediately');
    expect(seenEntries.last.single.id, 'e1', reason: 'it should close the entry, not add one');
  });

  test('a failed write is rolled back', () async {
    fake.entries.add(const []);
    await pump();

    final errors = <Object>[];
    repo.writeErrors.listen(errors.add);

    unawaited(repo.toggleTimer(taskId: 'task1', memberId: 'me'));
    await pump();
    expect(seenEntries.last, hasLength(1), reason: 'optimistically added');

    fake.gate!.completeError(Exception('offline'));
    await pump();

    expect(seenEntries.last, isEmpty, reason: 'the optimistic entry should be gone');
    expect(errors, hasLength(1), reason: 'and the failure should be reported');
  });

  test('a snapshot landing mid-flight does not drop the in-flight change', () async {
    fake.entries.add(const []);
    await pump();

    unawaited(repo.toggleTimer(taskId: 'task1', memberId: 'me'));
    await pump();
    expect(seenEntries.last, hasLength(1));

    // Someone else edits something; the repo re-fetches and the snapshot that
    // comes back predates our write.
    fake.entries.add(const []);
    await pump();

    expect(seenEntries.last, hasLength(1),
        reason: 'our un-acknowledged entry must survive a stale snapshot');
  });

  test('the optimistic copy is dropped once the real record arrives', () async {
    fake.entries.add(const []);
    await pump();

    unawaited(repo.toggleTimer(taskId: 'task1', memberId: 'me'));
    await pump();

    fake.gate!.complete();
    await pump();

    // Still shown — the server has acknowledged, but its snapshot hasn't landed.
    expect(seenEntries.last, hasLength(1));

    final real = TimeEntry(
      id: 'server1',
      taskId: 'task1',
      memberId: 'me',
      startedAt: DateTime.now(),
    );
    fake.entries.add([real]);
    await pump();

    expect(seenEntries.last, hasLength(1), reason: 'exactly one entry, not a duplicate');
    expect(seenEntries.last.single.id, 'server1', reason: 'the server record wins');
  });

  test('deleting a task also clears its time entries', () async {
    final task = Task(id: 'task1', workId: 'w1', title: 'x');
    fake.tasks.add([task]);
    fake.entries.add([
      TimeEntry(id: 'e1', taskId: 'task1', memberId: 'me', startedAt: DateTime.now()),
      TimeEntry(id: 'e2', taskId: 'other', memberId: 'me', startedAt: DateTime.now()),
    ]);
    await pump();

    unawaited(repo.deleteTask('task1'));
    await pump();

    expect(seenTasks.last, isEmpty);
    expect(seenEntries.last, hasLength(1), reason: "the other task's entry is untouched");
    expect(seenEntries.last.single.id, 'e2');
  });

  test('an upload shows up right away, flagged as still in flight', () async {
    fake.attachments.add(const []);
    await pump();

    unawaited(repo.addAttachment(
      taskId: 'task1',
      memberId: 'me',
      filename: 'whiteboard.png',
      bytes: someBytes,
    ));
    await pump();

    expect(fake.gate!.isCompleted, isFalse, reason: 'the bytes are still crossing the wire');
    expect(seenFiles.last, hasLength(1));
    expect(seenFiles.last.single.uploading, isTrue);
    expect(seenFiles.last.single.name, 'whiteboard.png');
    expect(seenFiles.last.single.localBytes, isNotNull,
        reason: 'images preview from memory while uploading');
  });

  test('a non-image upload does not park its bytes in memory', () async {
    fake.attachments.add(const []);
    await pump();

    unawaited(repo.addAttachment(
      taskId: 'task1',
      memberId: 'me',
      filename: 'spec.pdf',
      bytes: someBytes,
    ));
    await pump();

    expect(seenFiles.last.single.localBytes, isNull);
    expect(seenFiles.last.single.isImage, isFalse);
  });

  test('the placeholder is replaced by the real file, not joined by it', () async {
    fake.attachments.add(const []);
    await pump();

    unawaited(repo.addAttachment(
      taskId: 'task1',
      memberId: 'me',
      filename: 'whiteboard.png',
      bytes: someBytes,
    ));
    await pump();

    fake.gate!.complete();
    await pump();

    expect(seenFiles.last, hasLength(1), reason: 'placeholder swapped out, not duplicated');
    expect(seenFiles.last.single.id, 'server-file');
    expect(seenFiles.last.single.uploading, isFalse,
        reason: 'the spinner should clear on the ack, not on the next snapshot');

    // The realtime snapshot finally lands with the same record.
    fake.attachments.add([seenFiles.last.single]);
    await pump();
    expect(seenFiles.last, hasLength(1));
  });

  test('a failed upload leaves nothing behind', () async {
    fake.attachments.add(const []);
    await pump();

    final errors = <Object>[];
    repo.writeErrors.listen(errors.add);

    unawaited(repo.addAttachment(
      taskId: 'task1',
      memberId: 'me',
      filename: 'whiteboard.png',
      bytes: someBytes,
    ));
    await pump();
    expect(seenFiles.last, hasLength(1));

    fake.gate!.completeError(Exception('upload died'));
    await pump();

    expect(seenFiles.last, isEmpty);
    expect(errors, hasLength(1));
  });

  test('deleting a task also clears its attachments', () async {
    fake.tasks.add([Task(id: 'task1', workId: 'w1', title: 'x')]);
    fake.attachments.add([
      Attachment(
          id: 'a1', taskId: 'task1', memberId: 'me', name: 'a.png', created: DateTime.now()),
      Attachment(
          id: 'a2', taskId: 'other', memberId: 'me', name: 'b.png', created: DateTime.now()),
    ]);
    await pump();

    unawaited(repo.deleteTask('task1'));
    await pump();

    expect(seenFiles.last, hasLength(1), reason: "the other task's file is untouched");
    expect(seenFiles.last.single.id, 'a2');
  });

  test('task edits apply immediately and revert on failure', () async {
    fake.tasks.add([Task(id: 'task1', workId: 'w1', title: 'x')]);
    await pump();

    unawaited(repo.setTaskDone('task1', true));
    await pump();
    expect(seenTasks.last.single.isDone, isTrue);
    expect(seenTasks.last.single.doneAt, isNotNull);

    fake.gate!.completeError(Exception('nope'));
    await pump();
    expect(seenTasks.last.single.isDone, isFalse, reason: 'reverted');
  });

  test('renaming a task shows the new title before the server replies', () async {
    fake.tasks.add([Task(id: 'task1', workId: 'w1', title: 'old')]);
    await pump();

    unawaited(repo.renameTask('task1', 'new'));
    await pump();

    expect(fake.gate!.isCompleted, isFalse);
    expect(seenTasks.last.single.title, 'new');

    fake.gate!.completeError(Exception('nope'));
    await pump();
    expect(seenTasks.last.single.title, 'old', reason: 'reverted');
  });

  test('renaming a Work shows the new title before the server replies', () async {
    final seenWorks = <List<Work>>[];
    repo.watchWorks().listen(seenWorks.add);
    fake.works.add([const Work(id: 'w1', title: 'old')]);
    await pump();

    unawaited(repo.renameWork('w1', 'new'));
    await pump();

    expect(fake.gate!.isCompleted, isFalse);
    expect(seenWorks.last.single.title, 'new');

    fake.gate!.completeError(Exception('nope'));
    await pump();
    expect(seenWorks.last.single.title, 'old', reason: 'reverted');
  });
}
