import { pb, actorHeaders, currentMemberId } from "./pb";
import { getState } from "./store";
import {
  optimisticCreate,
  optimisticDelete,
  optimisticUpdate,
  tempId,
} from "./sync";
import { writeDate, writeDateOrClear } from "../models/wire";
import type { Work } from "../models/work";
import type { Task } from "../models/task";
import type { TimeEntry } from "../models/timeEntry";
import type { Attachment } from "../models/attachment";
import { effectiveEnd } from "../models/timeMath";

/* Every write the app performs, ported from pocketbase_repo.dart.
 *
 * Components read the store and call these. They never fetch — video_editor's
 * second rule, and the one that kept its view replaceable while the model stood
 * still. It is also what optimistic_repo.dart already was.
 *
 * Every mutating call carries the actor headers so history.pb.js can attribute
 * it. Reads never do: a read is not an event.
 */

const H = () => ({ headers: actorHeaders() });

/* `position` is a creation timestamp used only as a sort tie-break. It is
 * written once, here, and never updated — there is no reorder anywhere in this
 * app, in the Dart or here, and the board's order is DERIVED (works sort by
 * completeness, tasks by position). Do not add a drag handle without deciding
 * what position then means. */
const newPosition = (): number => Date.now();

/* ---- works -------------------------------------------------------------- */

export function createWork(title: string): Promise<Work | null> {
  const placeholder: Work = {
    id: tempId(),
    title: title.trim(),
    position: newPosition(),
    archived: false,
  };
  return optimisticCreate<Work>("works", placeholder, () =>
    pb.collection("works").create(
      { title: placeholder.title, position: placeholder.position, archived: false },
      H(),
    ),
  );
}

export function renameWork(work: Work, title: string): Promise<Work | null> {
  return optimisticUpdate<Work>("works", work.id, { ...work, title: title.trim() }, () =>
    pb.collection("works").update(work.id, { title: title.trim() }, H()),
  );
}

export function setWorkArchived(work: Work, archived: boolean): Promise<Work | null> {
  return optimisticUpdate<Work>("works", work.id, { ...work, archived }, () =>
    pb.collection("works").update(work.id, { archived }, H()),
  );
}

/* Deleting a work cascades to its tasks, their time entries and their
 * attachments — server-side, via cascadeDelete on the relations. The realtime
 * events for all of them do arrive, so the only reason to hide the children
 * locally is to stop the board's totals flickering for the ~50ms before they
 * land. */
export function deleteWork(workId: string): Promise<null> {
  const s = getState();
  const taskIds = s.tasks.filter((t) => t.workId === workId).map((t) => t.id);
  const taskSet = new Set(taskIds);
  return optimisticDelete(
    "works",
    workId,
    () => pb.collection("works").delete(workId, H()),
    [
      { key: "tasks", ids: taskIds },
      { key: "entries", ids: s.entries.filter((e) => taskSet.has(e.taskId)).map((e) => e.id) },
      { key: "attachments", ids: s.attachments.filter((a) => taskSet.has(a.taskId)).map((a) => a.id) },
    ],
  );
}

/* ---- tasks -------------------------------------------------------------- */

export function createTask(workId: string, title: string): Promise<Task | null> {
  const placeholder: Task = {
    id: tempId(),
    workId,
    title: title.trim(),
    isDone: false,
    doneAt: null,
    isArchived: false,
    note: "",
    dueDate: null,
    critical: false,
    position: newPosition(),
  };
  return optimisticCreate<Task>("tasks", placeholder, () =>
    pb.collection("tasks").create(
      {
        work: workId,
        title: placeholder.title,
        position: placeholder.position,
        is_done: false,
        is_archived: false,
        critical: false,
        note: "",
      },
      H(),
    ),
  );
}

export function renameTask(task: Task, title: string): Promise<Task | null> {
  return optimisticUpdate<Task>("tasks", task.id, { ...task, title: title.trim() }, () =>
    pb.collection("tasks").update(task.id, { title: title.trim() }, H()),
  );
}

/* `is_done` and `done_at` move together, and un-doing CLEARS done_at by sending
 * '' — not null, which PocketBase rejects for a date field. */
export function setTaskDone(task: Task, done: boolean): Promise<Task | null> {
  const doneAt = done ? new Date() : null;
  return optimisticUpdate<Task>("tasks", task.id, { ...task, isDone: done, doneAt }, () =>
    pb.collection("tasks").update(
      task.id,
      { is_done: done, done_at: writeDateOrClear(doneAt) },
      H(),
    ),
  );
}

export function setTaskArchived(task: Task, archived: boolean): Promise<Task | null> {
  return optimisticUpdate<Task>("tasks", task.id, { ...task, isArchived: archived }, () =>
    pb.collection("tasks").update(task.id, { is_archived: archived }, H()),
  );
}

export function setTaskNote(task: Task, note: string): Promise<Task | null> {
  const n = note.trim(); // server caps `note` at 500 chars
  return optimisticUpdate<Task>("tasks", task.id, { ...task, note: n }, () =>
    pb.collection("tasks").update(task.id, { note: n }, H()),
  );
}

export function setTaskDueDate(task: Task, due: Date | null): Promise<Task | null> {
  return optimisticUpdate<Task>("tasks", task.id, { ...task, dueDate: due }, () =>
    pb.collection("tasks").update(task.id, { due_date: writeDateOrClear(due) }, H()),
  );
}

export function setTaskCritical(task: Task, critical: boolean): Promise<Task | null> {
  return optimisticUpdate<Task>("tasks", task.id, { ...task, critical }, () =>
    pb.collection("tasks").update(task.id, { critical }, H()),
  );
}

export function deleteTask(taskId: string): Promise<null> {
  const s = getState();
  return optimisticDelete(
    "tasks",
    taskId,
    () => pb.collection("tasks").delete(taskId, H()),
    [
      { key: "entries", ids: s.entries.filter((e) => e.taskId === taskId).map((e) => e.id) },
      { key: "attachments", ids: s.attachments.filter((a) => a.taskId === taskId).map((a) => a.id) },
    ],
  );
}

/* ---- timers ------------------------------------------------------------- */

/* One toggle per (task, member) may be in the air at a time.
 *
 * Straight from the Dart's `_togglesInFlight`, and the reason is the same: this
 * is a read-then-write, so a double-tap can read "nothing open" twice and
 * create two live entries for one person on one task. */
const togglesInFlight = new Set<string>();

/**
 * Start or stop MY timer on a task.
 *
 * Other people's entries are untouched — the model allows concurrent entries
 * and one person stopping is not the task stopping.
 */
export async function toggleTimer(taskId: string): Promise<void> {
  const memberId = currentMemberId();
  if (!memberId) return;

  const key = `${taskId}/${memberId}`;
  if (togglesInFlight.has(key)) return;
  togglesInFlight.add(key);

  try {
    const open = getState().entries.filter(
      (e) => e.taskId === taskId && e.memberId === memberId && e.endedAt === null,
    );

    if (open.length > 0) {
      const now = new Date();
      /* Close ALL of them, not just the first. The Dart does this deliberately:
       * if duplicates ever appear — a lost response, two devices, an old bug —
       * pressing stop should end the day's ambiguity rather than leave one
       * ticking invisibly behind the other. */
      await Promise.all(open.map((e) => stopEntry(e, now)));
      return;
    }

    const placeholder: TimeEntry = {
      id: tempId(),
      taskId,
      memberId,
      startedAt: new Date(),
      endedAt: null,
    };
    await optimisticCreate<TimeEntry>("entries", placeholder, () =>
      pb.collection("time_entries").create(
        {
          task: taskId,
          member: memberId,
          started_at: writeDate(placeholder.startedAt),
          ended_at: "", // '' is how PocketBase spells "no value" — and LIVE
        },
        H(),
      ),
    );
  } finally {
    togglesInFlight.delete(key);
  }
}

/**
 * Close one entry.
 *
 * Writes `effectiveEnd`, NOT `now`. For an entry inside the three-hour cap
 * those are the same; for one that has already run past it, `effectiveEnd` is
 * `started_at + 3h` — which is the number the board has been showing all along.
 * Writing `now` instead would bank six hours the moment somebody finally
 * noticed a timer left running overnight.
 */
export function stopEntry(entry: TimeEntry, now = new Date()): Promise<TimeEntry | null> {
  const endedAt = effectiveEnd(entry, now);
  return optimisticUpdate<TimeEntry>("entries", entry.id, { ...entry, endedAt }, () =>
    pb.collection("time_entries").update(
      entry.id,
      { ended_at: writeDate(endedAt) },
      H(),
    ),
  );
}

/**
 * Close every entry that has outlived the cap.
 *
 * Belt to the server sweep's braces: a browser can only close a timer while a
 * browser is open, and close_runaway_timers.pb.js is what makes it true when
 * nobody is looking. Both write the same value, so it does not matter which
 * gets there first — and because `effectiveEnd` already caps the arithmetic,
 * neither one changes a number anybody can see.
 */
export async function closeExpiredTimers(now = new Date()): Promise<void> {
  const memberId = currentMemberId();
  if (!memberId) return;
  const mine = getState().entries.filter(
    (e) =>
      e.memberId === memberId &&
      e.endedAt === null &&
      !e.id.startsWith("tmp_") && // not yet real; it has no server row to update
      now.getTime() - e.startedAt.getTime() >= 3 * 60 * 60 * 1000,
  );
  await Promise.all(mine.map((e) => stopEntry(e, now)));
}

/* ---- attachments (the per-task ones; the shared drive is filesApi.ts) ---- */

export async function addAttachment(taskId: string, file: File): Promise<Attachment | null> {
  const memberId = currentMemberId();
  if (!memberId) return null;

  const body = new FormData();
  body.set("task", taskId);
  body.set("member", memberId);
  body.set("name", file.name);
  body.set("size", String(file.size));
  body.set("file", file, file.name);

  const placeholder: Attachment = {
    id: tempId(),
    taskId,
    memberId,
    name: file.name,
    url: "",
    thumbUrl: "",
    size: file.size,
    created: new Date(),
    uploading: true,
    /* An object URL so an image previews the instant it is picked rather than
     * after the round trip. Revoked when the real record replaces it. */
    localPreview: file.type.startsWith("image/") ? URL.createObjectURL(file) : null,
  };

  const saved = await optimisticCreate<Attachment>("attachments", placeholder, () =>
    pb.collection("attachments").create(body, H()),
  );
  if (placeholder.localPreview) URL.revokeObjectURL(placeholder.localPreview);
  return saved;
}

export function deleteAttachment(id: string): Promise<null> {
  return optimisticDelete("attachments", id, () =>
    pb.collection("attachments").delete(id, H()),
  );
}

/** The per-file ceiling the `attachments` migration enforces server-side.
 *  Checked here too so an oversized pick is refused with a sentence instead of
 *  a 400. Raise them together or the client accepts what the server rejects. */
export const MAX_ATTACHMENT_BYTES = 20 * 1024 * 1024;
