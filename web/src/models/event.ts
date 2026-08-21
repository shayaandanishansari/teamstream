import type { RecordModel } from "pocketbase";
import { readBool, readDate, readRel, readStr } from "./wire";

/** Port of app/lib/models/event.dart.
 *
 * Ported for completeness, not for use: calendar_screen.dart is a 24-line
 * placeholder and nothing in the app calls createEvent. The collection exists,
 * so the model exists; the screen stays a stub. */
export interface CalendarEvent {
  id: string;
  title: string;
  date: Date;
  allDay: boolean;  // wire: "all_day"
  note: string;
  taskId: string | null; // wire: "task", '' when unset
}

export const toCalendarEvent = (r: RecordModel): CalendarEvent => ({
  id: r.id,
  title: readStr(r.title),
  date: readDate(r.date) ?? new Date(),
  allDay: readBool(r.all_day),
  note: readStr(r.note),
  taskId: readRel(r.task),
});
