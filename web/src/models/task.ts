import type { RecordModel } from "pocketbase";
import { readBool, readDate, readNum, readStr } from "./wire";

/** Port of app/lib/models/task.dart.
 *  Note the wire names: the relation is `work`, and the flags are snake_case. */
export interface Task {
  id: string;
  workId: string;      // wire: "work"
  title: string;
  isDone: boolean;     // wire: "is_done"
  doneAt: Date | null; // wire: "done_at"
  isArchived: boolean; // wire: "is_archived"
  note: string;
  dueDate: Date | null; // wire: "due_date"
  critical: boolean;
  position: number;
}

export const toTask = (r: RecordModel): Task => ({
  id: r.id,
  workId: readStr(r.work),
  title: readStr(r.title),
  isDone: readBool(r.is_done),
  doneAt: readDate(r.done_at),
  isArchived: readBool(r.is_archived),
  note: readStr(r.note),
  dueDate: readDate(r.due_date),
  critical: readBool(r.critical),
  position: readNum(r.position),
});
