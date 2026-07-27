import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:pocketbase/pocketbase.dart';

import '../models/attachment.dart';
import '../models/member.dart';
import '../models/work.dart';
import '../models/task.dart';
import '../models/time_entry.dart';
import '../models/event.dart';
import 'team_stream_repo.dart';

/// PocketBase-backed implementation. The only file that imports pocketbase.
class PocketBaseRepo implements TeamStreamRepo {
  PocketBaseRepo(this.pb);

  final PocketBase pb;
  final List<UnsubscribeFunc> _unsubs = [];

  String _actorId = '';
  String _actorName = '';

  @override
  void setActor(String memberId, String memberName) {
    _actorId = memberId;
    _actorName = memberName;
  }

  /// Sent on every mutating call so the server-side history hook can attribute
  /// the change to a member (see backend/pb_hooks/history.pb.js).
  Map<String, String> get _actorHeaders => {
        'X-Actor-Id': _actorId,
        'X-Actor-Name': _actorName,
      };

  // ---- mapping RecordModel -> pure models ----
  DateTime? _date(String s) => s.isEmpty ? null : DateTime.tryParse(s)?.toLocal();
  String _iso(DateTime d) => d.toUtc().toIso8601String();

  Member _member(RecordModel r) => Member(
        id: r.id,
        name: r.getStringValue('name'),
        color: r.getStringValue('color', '#00A896'),
      );

  Work _work(RecordModel r) => Work(
        id: r.id,
        title: r.getStringValue('title'),
        position: r.getDoubleValue('position'),
        archived: r.getBoolValue('archived'),
      );

  Task _task(RecordModel r) => Task(
        id: r.id,
        workId: r.getStringValue('work'),
        title: r.getStringValue('title'),
        isDone: r.getBoolValue('is_done'),
        doneAt: _date(r.getStringValue('done_at')),
        isArchived: r.getBoolValue('is_archived'),
        note: r.getStringValue('note'),
        dueDate: _date(r.getStringValue('due_date')),
        critical: r.getBoolValue('critical'),
        position: r.getDoubleValue('position'),
      );

  TimeEntry _entry(RecordModel r) => TimeEntry(
        id: r.id,
        taskId: r.getStringValue('task'),
        memberId: r.getStringValue('member'),
        startedAt: _date(r.getStringValue('started_at')) ?? DateTime.now(),
        endedAt: _date(r.getStringValue('ended_at')),
      );

  CalendarEvent _event(RecordModel r) {
    final taskId = r.getStringValue('task');
    return CalendarEvent(
      id: r.id,
      title: r.getStringValue('title'),
      date: _date(r.getStringValue('date')) ?? DateTime.now(),
      allDay: r.getBoolValue('all_day'),
      note: r.getStringValue('note'),
      taskId: taskId.isEmpty ? null : taskId,
    );
  }

  Attachment _attachment(RecordModel r) {
    final stored = r.getStringValue('file');
    return Attachment(
      id: r.id,
      taskId: r.getStringValue('task'),
      memberId: r.getStringValue('member'),
      name: r.getStringValue('name'),
      url: stored.isEmpty ? '' : pb.files.getURL(r, stored).toString(),
      thumbUrl:
          stored.isEmpty ? '' : pb.files.getURL(r, stored, thumb: '240x240').toString(),
      size: r.getIntValue('size'),
      created: _date(r.getStringValue('created')) ?? DateTime.now(),
    );
  }

  /// Initial full fetch, then re-fetch on any realtime event for the collection.
  Stream<List<T>> _watch<T>(String collection, T Function(RecordModel) map) {
    late StreamController<List<T>> controller;
    UnsubscribeFunc? unsub;

    Future<void> load() async {
      try {
        final records = await pb.collection(collection).getFullList();
        if (!controller.isClosed) controller.add(records.map(map).toList());
      } catch (e, st) {
        if (!controller.isClosed) controller.addError(e, st);
      }
    }

    controller = StreamController<List<T>>.broadcast(
      onListen: () async {
        await load();
        unsub = await pb.collection(collection).subscribe('*', (_) => load());
        if (unsub != null) _unsubs.add(unsub!);
      },
      onCancel: () async {
        await unsub?.call();
      },
    );
    return controller.stream;
  }

  @override
  Future<List<Member>> fetchMembers() async {
    final records = await pb.collection('members').getFullList();
    return records.map(_member).toList();
  }

  // ---- auth (shared-password gate) ----

  /// Login identity is an internal email derived from the name (never shown to
  /// the user), matching how members are seeded (see the seed migration).
  String _emailFor(String name) => '${name.trim().toLowerCase()}@teamstream.local';

  @override
  Future<Member> authenticate(String name, String password) async {
    final res =
        await pb.collection('members').authWithPassword(_emailFor(name), password);
    final me = _member(res.record);
    setActor(me.id, me.name);
    return me;
  }

  @override
  bool get isAuthenticated => pb.authStore.isValid;

  @override
  Member? get currentMember {
    if (!pb.authStore.isValid) return null;
    final r = pb.authStore.record;
    return r == null ? null : _member(r);
  }

  @override
  void signOut() => pb.authStore.clear();

  @override
  Stream<List<Work>> watchWorks() => _watch('works', _work);

  @override
  Stream<List<Task>> watchTasks() => _watch('tasks', _task);

  @override
  Stream<List<TimeEntry>> watchTimeEntries() => _watch('time_entries', _entry);

  @override
  Stream<List<CalendarEvent>> watchEvents() => _watch('events', _event);

  @override
  Stream<List<Attachment>> watchAttachments() => _watch('attachments', _attachment);

  /// Toggles already in flight, keyed by "task/member". The toggle is a
  /// read-then-write, so without this a fast double-tap has both taps read
  /// "no open entry" and both create one — leaving a second timer running
  /// invisibly until someone taps again.
  final _togglesInFlight = <String>{};

  @override
  Future<void> toggleTimer({required String taskId, required String memberId}) async {
    final key = '$taskId/$memberId';
    if (!_togglesInFlight.add(key)) return; // a toggle for this pair is mid-air
    try {
      final existing = await pb.collection('time_entries').getFullList(
            filter: 'task="$taskId" && member="$memberId"',
          );
      final open = existing.where((r) => r.getStringValue('ended_at').isEmpty).toList();

      if (open.isNotEmpty) {
        // Close ALL of my open entries on this task, not just the first. If a
        // duplicate ever slipped through, this is what cleans it up.
        final endedAt = _iso(DateTime.now());
        for (final r in open) {
          await pb.collection('time_entries').update(r.id,
              body: {'ended_at': endedAt}, headers: _actorHeaders);
        }
      } else {
        await pb.collection('time_entries').create(body: {
          'task': taskId,
          'member': memberId,
          'started_at': _iso(DateTime.now()),
          'ended_at': '',
        }, headers: _actorHeaders);
      }
    } finally {
      _togglesInFlight.remove(key);
    }
  }

  @override
  Future<Work> createWork(String title) async {
    final r = await pb.collection('works').create(body: {
      'title': title,
      'position': DateTime.now().millisecondsSinceEpoch.toDouble(),
      'archived': false,
    }, headers: _actorHeaders);
    return _work(r);
  }

  @override
  Future<Task> createTask({required String workId, required String title}) async {
    final r = await pb.collection('tasks').create(body: {
      'work': workId,
      'title': title,
      'position': DateTime.now().millisecondsSinceEpoch.toDouble(),
      'is_done': false,
      'is_archived': false,
      'critical': false,
      'note': '',
    }, headers: _actorHeaders);
    return _task(r);
  }

  @override
  Future<void> deleteTask(String taskId) async {
    await pb.collection('tasks').delete(taskId, headers: _actorHeaders);
  }

  @override
  Future<void> deleteWork(String workId) async {
    await pb.collection('works').delete(workId, headers: _actorHeaders);
  }

  @override
  Future<void> setTaskDone(String taskId, bool done) async {
    await pb.collection('tasks').update(taskId, body: {
      'is_done': done,
      'done_at': done ? _iso(DateTime.now()) : '',
    }, headers: _actorHeaders);
  }

  @override
  Future<void> setTaskArchived(String taskId, bool archived) async {
    await pb.collection('tasks').update(taskId,
        body: {'is_archived': archived}, headers: _actorHeaders);
  }

  @override
  Future<void> updateTaskNote(String taskId, String note) async {
    await pb.collection('tasks').update(taskId, body: {'note': note}, headers: _actorHeaders);
  }

  @override
  Future<void> setTaskDueDate(String taskId, DateTime? due) async {
    await pb.collection('tasks').update(taskId,
        body: {'due_date': due == null ? '' : _iso(due)}, headers: _actorHeaders);
  }

  @override
  Future<void> setTaskCritical(String taskId, bool critical) async {
    await pb.collection('tasks').update(taskId,
        body: {'critical': critical}, headers: _actorHeaders);
  }

  @override
  Future<Attachment> addAttachment({
    required String taskId,
    required String memberId,
    required String filename,
    required Uint8List bytes,
  }) async {
    final r = await pb.collection('attachments').create(
      body: {
        'task': taskId,
        'member': memberId,
        'name': filename,
        'size': bytes.length,
      },
      files: [http.MultipartFile.fromBytes('file', bytes, filename: filename)],
      headers: _actorHeaders,
    );
    return _attachment(r);
  }

  @override
  Future<void> deleteAttachment(String attachmentId) async {
    await pb.collection('attachments').delete(attachmentId, headers: _actorHeaders);
  }

  @override
  Future<CalendarEvent> createEvent({
    required String title,
    required DateTime date,
    bool allDay = true,
    String note = '',
  }) async {
    final r = await pb.collection('events').create(body: {
      'title': title,
      'date': _iso(date),
      'all_day': allDay,
      'note': note,
    }, headers: _actorHeaders);
    return _event(r);
  }

  @override
  void dispose() {
    for (final u in _unsubs) {
      u();
    }
    _unsubs.clear();
  }
}
