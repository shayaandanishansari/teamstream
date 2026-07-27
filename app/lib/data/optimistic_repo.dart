import 'dart:async';

import '../models/member.dart';
import '../models/work.dart';
import '../models/task.dart';
import '../models/time_entry.dart';
import '../models/event.dart';
import 'team_stream_repo.dart';

/// Makes writes feel instant.
///
/// Without this, every action costs two sequential round trips: the write, then
/// the realtime event that triggers a full re-fetch — and only then does the UI
/// move. Over the tunnel that's a visible lag on every tap.
///
/// This wraps ANY [TeamStreamRepo] and applies the change to the local view
/// immediately, then sends it. The server stays authoritative: an optimistic
/// copy is held only until the next server snapshot arrives (which contains the
/// real record), then dropped. A write that fails is rolled back and reported
/// on [writeErrors].
///
/// It's a decorator rather than logic inside PocketBaseRepo so the seam stays
/// swappable — a future mesh or mock backend gets this behaviour for free.
class OptimisticRepo implements TeamStreamRepo {
  OptimisticRepo(this._inner);

  final TeamStreamRepo _inner;

  late final _works = _Layer<Work>(_inner.watchWorks, (w) => w.id);
  late final _tasks = _Layer<Task>(_inner.watchTasks, (t) => t.id);
  late final _entries = _Layer<TimeEntry>(_inner.watchTimeEntries, (e) => e.id);
  late final _events = _Layer<CalendarEvent>(_inner.watchEvents, (e) => e.id);

  int _tmp = 0;
  String _tempId() => 'tmp_${++_tmp}';

  // ---- write status, for the UI ----

  int _inFlight = 0;
  final _pending = StreamController<int>.broadcast();
  final _errors = StreamController<Object>.broadcast();

  /// How many writes are currently in the air. 0 means everything has landed.
  Stream<int> get pendingWrites => _pending.stream;

  /// Emits when a write failed and its optimistic change was rolled back.
  Stream<Object> get writeErrors => _errors.stream;

  /// Runs a write with its optimistic change already applied. Never rethrows:
  /// a failure rolls the change back and surfaces on [writeErrors], so callers
  /// (and the widget tree) don't have to handle it inline.
  Future<T?> _send<T>(
    Future<T> Function() call, {
    required void Function() settle,
    required void Function() rollback,
  }) async {
    _inFlight++;
    _pending.add(_inFlight);
    try {
      final result = await call();
      settle();
      return result;
    } catch (e) {
      rollback();
      _errors.add(e);
      return null;
    } finally {
      _inFlight--;
      _pending.add(_inFlight);
    }
  }

  // ---- reads: the projected (server + optimistic) view ----

  @override
  Stream<List<Work>> watchWorks() => _works.stream;

  @override
  Stream<List<Task>> watchTasks() => _tasks.stream;

  @override
  Stream<List<TimeEntry>> watchTimeEntries() => _entries.stream;

  @override
  Stream<List<CalendarEvent>> watchEvents() => _events.stream;

  // ---- writes ----

  @override
  Future<void> toggleTimer({required String taskId, required String memberId}) async {
    TimeEntry? open;
    for (final e in _entries.view) {
      if (e.taskId == taskId && e.memberId == memberId && e.isLive) {
        open = e;
        break;
      }
    }

    final String key;
    if (open != null) {
      key = open.id;
      _entries.upsert(open.stopped(DateTime.now()));
    } else {
      key = _tempId();
      _entries.upsert(TimeEntry(
        id: key,
        taskId: taskId,
        memberId: memberId,
        startedAt: DateTime.now(),
      ));
    }

    await _send(
      () => _inner.toggleTimer(taskId: taskId, memberId: memberId),
      settle: () => _entries.settle([key]),
      rollback: () => _entries.rollback([key]),
    );
  }

  @override
  Future<Work> createWork(String title) async {
    final temp = Work(
      id: _tempId(),
      title: title,
      position: DateTime.now().millisecondsSinceEpoch.toDouble(),
    );
    _works.upsert(temp);

    final saved = await _send(
      () => _inner.createWork(title),
      settle: () => _works.settle([temp.id]),
      rollback: () => _works.rollback([temp.id]),
    );
    // On failure the optimistic Work has already been rolled back out of the
    // view and the error reported; the returned value is unused by callers.
    return saved ?? temp;
  }

  @override
  Future<Task> createTask({required String workId, required String title}) async {
    final temp = Task(
      id: _tempId(),
      workId: workId,
      title: title,
      position: DateTime.now().millisecondsSinceEpoch.toDouble(),
    );
    _tasks.upsert(temp);

    final saved = await _send(
      () => _inner.createTask(workId: workId, title: title),
      settle: () => _tasks.settle([temp.id]),
      rollback: () => _tasks.rollback([temp.id]),
    );
    return saved ?? temp;
  }

  @override
  Future<void> deleteTask(String taskId) async {
    // Mirror the server's cascade, or the tile vanishes while its tracked time
    // lingers in the totals until the next snapshot.
    final entryIds = [
      for (final e in _entries.view)
        if (e.taskId == taskId) e.id
    ];
    _tasks.remove(taskId);
    _entries.removeAll(entryIds);

    await _send(
      () => _inner.deleteTask(taskId),
      settle: () {
        _tasks.settle([taskId]);
        _entries.settle(entryIds);
      },
      rollback: () {
        _tasks.rollback([taskId]);
        _entries.rollback(entryIds);
      },
    );
  }

  @override
  Future<void> deleteWork(String workId) async {
    final taskIds = [
      for (final t in _tasks.view)
        if (t.workId == workId) t.id
    ];
    final entryIds = [
      for (final e in _entries.view)
        if (taskIds.contains(e.taskId)) e.id
    ];
    _works.remove(workId);
    _tasks.removeAll(taskIds);
    _entries.removeAll(entryIds);

    await _send(
      () => _inner.deleteWork(workId),
      settle: () {
        _works.settle([workId]);
        _tasks.settle(taskIds);
        _entries.settle(entryIds);
      },
      rollback: () {
        _works.rollback([workId]);
        _tasks.rollback(taskIds);
        _entries.rollback(entryIds);
      },
    );
  }

  @override
  Future<void> setTaskDone(String taskId, bool done) => _patchTask(
        taskId,
        (t) => t.copyWith(isDone: done, doneAt: done ? DateTime.now() : null),
        () => _inner.setTaskDone(taskId, done),
      );

  @override
  Future<void> setTaskArchived(String taskId, bool archived) => _patchTask(
        taskId,
        (t) => t.copyWith(isArchived: archived),
        () => _inner.setTaskArchived(taskId, archived),
      );

  @override
  Future<void> updateTaskNote(String taskId, String note) => _patchTask(
        taskId,
        (t) => t.copyWith(note: note),
        () => _inner.updateTaskNote(taskId, note),
      );

  @override
  Future<void> setTaskDueDate(String taskId, DateTime? due) => _patchTask(
        taskId,
        (t) => t.copyWith(dueDate: due),
        () => _inner.setTaskDueDate(taskId, due),
      );

  @override
  Future<void> setTaskCritical(String taskId, bool critical) => _patchTask(
        taskId,
        (t) => t.copyWith(critical: critical),
        () => _inner.setTaskCritical(taskId, critical),
      );

  Future<void> _patchTask(
    String taskId,
    Task Function(Task) patch,
    Future<void> Function() call,
  ) async {
    Task? current;
    for (final t in _tasks.view) {
      if (t.id == taskId) {
        current = t;
        break;
      }
    }
    if (current != null) _tasks.upsert(patch(current));

    await _send(
      call,
      settle: () => _tasks.settle([taskId]),
      rollback: () => _tasks.rollback([taskId]),
    );
  }

  @override
  Future<CalendarEvent> createEvent({
    required String title,
    required DateTime date,
    bool allDay = false,
    String note = '',
  }) async {
    final temp = CalendarEvent(
      id: _tempId(),
      title: title,
      date: date,
      allDay: allDay,
      note: note,
    );
    _events.upsert(temp);

    final saved = await _send(
      () => _inner.createEvent(title: title, date: date, allDay: allDay, note: note),
      settle: () => _events.settle([temp.id]),
      rollback: () => _events.rollback([temp.id]),
    );
    return saved ?? temp;
  }

  // ---- straight delegation ----

  @override
  Future<List<Member>> fetchMembers() => _inner.fetchMembers();

  @override
  Future<Member> authenticate(String name, String password) =>
      _inner.authenticate(name, password);

  @override
  bool get isAuthenticated => _inner.isAuthenticated;

  @override
  Member? get currentMember => _inner.currentMember;

  @override
  void signOut() => _inner.signOut();

  @override
  void setActor(String memberId, String memberName) => _inner.setActor(memberId, memberName);

  @override
  void dispose() {
    _works.dispose();
    _tasks.dispose();
    _entries.dispose();
    _events.dispose();
    _pending.close();
    _errors.close();
    _inner.dispose();
  }
}

/// One collection's view: the last server snapshot with local, not-yet-confirmed
/// changes laid over the top. The overlay is re-applied to every incoming
/// snapshot, so a re-fetch triggered by someone else's edit can't flicker our
/// own in-flight change away.
class _Layer<T> {
  _Layer(this._source, this.idOf);

  final Stream<List<T>> Function() _source;
  final String Function(T) idOf;

  StreamSubscription<List<T>>? _sub;
  List<T> _server = const [];

  final Map<String, T> _upserts = {};
  final Set<String> _deletes = {};

  /// Keys whose write the server has acknowledged. They stay in the overlay
  /// until the next snapshot — which is the one that contains the real record —
  /// so the optimistic copy is never dropped into a gap.
  final Set<String> _settled = {};

  late final StreamController<List<T>> _out = StreamController<List<T>>.broadcast(
    onListen: () {
      _sub ??= _source().listen(
        (records) {
          _server = records;
          for (final id in _settled) {
            _upserts.remove(id);
            _deletes.remove(id);
          }
          _settled.clear();
          _emit();
        },
        onError: (Object e, StackTrace st) {
          if (!_out.isClosed) _out.addError(e, st);
        },
      );
    },
  );

  Stream<List<T>> get stream => _out.stream;

  /// Server snapshot + overlay. Server order is preserved; optimistic creates
  /// land at the end (the board sorts by position anyway).
  List<T> get view {
    final byId = <String, T>{};
    for (final r in _server) {
      byId[idOf(r)] = r;
    }
    byId.addAll(_upserts);
    for (final id in _deletes) {
      byId.remove(id);
    }
    return byId.values.toList();
  }

  void _emit() {
    if (!_out.isClosed) _out.add(view);
  }

  void upsert(T value) {
    _upserts[idOf(value)] = value;
    _settled.remove(idOf(value));
    _emit();
  }

  void remove(String id) => removeAll([id]);

  void removeAll(Iterable<String> ids) {
    if (ids.isEmpty) return;
    _deletes.addAll(ids);
    _settled.removeAll(ids);
    _emit();
  }

  void settle(Iterable<String> ids) => _settled.addAll(ids);

  void rollback(Iterable<String> ids) {
    for (final id in ids) {
      _upserts.remove(id);
      _deletes.remove(id);
      _settled.remove(id);
    }
    _emit();
  }

  void dispose() {
    _sub?.cancel();
    _out.close();
  }
}
