import 'dart:typed_data';

import '../models/attachment.dart';
import '../models/member.dart';
import '../models/work.dart';
import '../models/task.dart';
import '../models/time_entry.dart';
import '../models/event.dart';

/// The swappable seam. The whole app talks to this interface; PocketBaseRepo is
/// the only thing that knows about PocketBase. Swap it (mesh, mock, other db)
/// without touching the UI.
abstract class TeamStreamRepo {
  Future<List<Member>> fetchMembers();

  // ---- auth (shared-password gate) ----

  /// Log in with the shared password. `name` is one of the members; the impl
  /// derives the backend login identity from it. Returns the signed-in member.
  Future<Member> authenticate(String name, String password);

  /// Whether there's a currently-valid session on this device.
  bool get isAuthenticated;

  /// The signed-in member (from the persisted session), or null.
  Member? get currentMember;

  /// Clear the session (log out).
  void signOut();

  Stream<List<Work>> watchWorks();
  Stream<List<Task>> watchTasks();
  Stream<List<TimeEntry>> watchTimeEntries();
  Stream<List<CalendarEvent>> watchEvents();
  Stream<List<Attachment>> watchAttachments();

  /// Toggle THIS member's timer on a task: stop their open entry if one exists,
  /// otherwise start a new one. Independent of anyone else's timers.
  Future<void> toggleTimer({required String taskId, required String memberId});

  Future<Work> createWork(String title);
  Future<Task> createTask({required String workId, required String title});

  /// Hard delete. Cascades: deleting a task removes its time_entries; deleting
  /// a Work removes all its tasks (and their time_entries).
  Future<void> deleteTask(String taskId);
  Future<void> deleteWork(String workId);

  Future<void> setTaskDone(String taskId, bool done);
  Future<void> setTaskArchived(String taskId, bool archived);
  Future<void> updateTaskNote(String taskId, String note);
  Future<void> setTaskDueDate(String taskId, DateTime? due);
  Future<void> setTaskCritical(String taskId, bool critical);

  /// Upload a file against a task, credited to [memberId]. Bytes rather than a
  /// path because web has no filesystem to hand out paths from.
  Future<Attachment> addAttachment({
    required String taskId,
    required String memberId,
    required String filename,
    required Uint8List bytes,
  });

  Future<void> deleteAttachment(String attachmentId);

  Future<CalendarEvent> createEvent({
    required String title,
    required DateTime date,
    bool allDay,
    String note,
  });

  /// Sets who "I" am, so server-side history can attribute changes to a member.
  void setActor(String memberId, String memberName);

  void dispose();
}
