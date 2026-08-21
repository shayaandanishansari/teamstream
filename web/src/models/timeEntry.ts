import type { RecordModel } from "pocketbase";
import { readDate, readStr } from "./wire";

/** Port of app/lib/models/time_entry.dart — the core mechanism.
 *  `endedAt === null` means LIVE right now. */
export interface TimeEntry {
  id: string;
  taskId: string;   // wire: "task"
  memberId: string; // wire: "member"
  startedAt: Date;  // wire: "started_at"
  endedAt: Date | null; // wire: "ended_at" — `''` on the wire
}

export const toTimeEntry = (r: RecordModel): TimeEntry => ({
  id: r.id,
  taskId: readStr(r.task),
  memberId: readStr(r.member),
  // The Dart falls back to DateTime.now() for an unparseable start. Kept: a
  // required field cannot really be absent, and a row that throws here would
  // take down the whole board rather than one row.
  startedAt: readDate(r.started_at) ?? new Date(),
  endedAt: readDate(r.ended_at),
});

export const isLive = (e: TimeEntry): boolean => e.endedAt === null;
