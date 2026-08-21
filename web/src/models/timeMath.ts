/* Calendar arithmetic for the Dashboard's day/week/month windows.
 * Ported from app/lib/models/time_math.dart. Pure functions, no imports.
 *
 * The Dart original's central warning survives the port intact: days are built
 * with the (y, m, d ± n) constructor rather than by adding 24 hours, because
 * across a DST boundary a "day" is not 24 hours and Duration arithmetic would
 * silently drift the window off midnight.
 *
 * JavaScript's Date happens to behave the same way — `new Date(y, m, d + 1)`
 * normalises through DST, `+86400000` does not — so the rule ports as written
 * rather than needing a different trick. Every function below constructs a new
 * Date from parts. None of them adds milliseconds.
 */

/* The shape lives in timeEntry.ts, next to the wire mapping that produces it.
 * Re-exported here so the arithmetic and the model can never drift into two
 * subtly different ideas of what an entry is. */
export type { TimeEntry } from "./timeEntry";
import type { TimeEntry } from "./timeEntry";

/* ---- the runaway-timer cap ------------------------------------------------
 *
 * A timer left running closes itself after three hours.
 *
 * The subtle part is not the number, it is WHERE the cap is applied. It is
 * enforced here, in the arithmetic, rather than only at the moment something
 * stops a timer — because nothing may be running to do the stopping. Close the
 * laptop with a timer going and nobody's browser is awake to notice; the record
 * in PocketBase just keeps having no `ended_at`.
 *
 * So `effectiveEnd` treats a live entry as having ended at start + 3h whether
 * or not anything has written that to the database yet. Every consumer — the
 * ticking display, a task's total, the dashboard's day and week windows — reads
 * the capped value, so a forgotten timer can never inflate a number anywhere,
 * even before it has been formally closed.
 *
 * A server-side sweep still has to run to actually set `ended_at`, or the row
 * stays open forever and every client pays this arithmetic to hide it. That
 * sweep is a PocketBase hook and belongs with the Phase 2 backend wiring; this
 * is the half that makes the UI correct in the meantime, and it stays correct
 * afterwards because both agree on the same rule.
 *
 * Three hours, not the wall clock: capping at "end of day" would credit a timer
 * started at 23:50 with ten minutes, which punishes the late worker for the
 * calendar. The cap is about how long one unattended session can be.
 */
export const MAX_SESSION_MS = 3 * 60 * 60 * 1000;

/**
 * When an entry really ended, honouring the cap.
 *
 * The cap applies ONLY to entries nobody stopped. An entry with an `endedAt` is
 * a person having pressed stop, and that is the truth about their day — capping
 * it would quietly delete real work from someone who genuinely sat there for
 * four hours. The rule is "a timer stops itself", not "no session may exceed
 * three hours", and those differ exactly where it matters.
 *
 * (Going forward a live timer can never reach four hours, because it closes
 * itself at three. Historical rows longer than that predate the cap and are
 * left intact rather than rewritten by arithmetic.)
 */
export function effectiveEnd(e: TimeEntry, now: Date): Date {
  if (e.endedAt !== null) return e.endedAt;
  const cap = new Date(e.startedAt.getTime() + MAX_SESSION_MS);
  return now < cap ? now : cap;
}

/** How long an entry ran, never more than the cap. Never negative. */
export function elapsedMs(e: TimeEntry, now: Date): number {
  return Math.max(0, effectiveEnd(e, now).getTime() - e.startedAt.getTime());
}

/**
 * A live entry that has already outlived the cap.
 *
 * This is the signal a client uses to close the record, and what the server
 * sweep looks for. It is deliberately separate from `elapsedMs`: the display
 * being right and the database being right are two different jobs, and only one
 * of them needs a write.
 */
export function hasExpired(e: TimeEntry, now: Date): boolean {
  return (
    e.endedAt === null &&
    now.getTime() - e.startedAt.getTime() >= MAX_SESSION_MS
  );
}

export const startOfDay = (d: Date): Date =>
  new Date(d.getFullYear(), d.getMonth(), d.getDate());

export const nextDay = (d: Date): Date =>
  new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1);

/**
 * Monday-anchored.
 *
 * Dart's DateTime.weekday numbers Mon..Sun as 1..7, so the original subtracts
 * `weekday - 1`. JavaScript's getDay() numbers Sun..Sat as 0..6, so a direct
 * transliteration would anchor the week to Sunday and quietly move every weekly
 * total by a day. Converted here rather than at the call sites.
 */
export function startOfWeek(d: Date): Date {
  const isoWeekday = d.getDay() === 0 ? 7 : d.getDay(); // Sun 0 -> 7
  return new Date(d.getFullYear(), d.getMonth(), d.getDate() - (isoWeekday - 1));
}

export const startOfMonth = (d: Date): Date =>
  new Date(d.getFullYear(), d.getMonth(), 1);

/**
 * How many milliseconds of `e` land inside `[from, to)`, with a live entry
 * treated as running up to `now`.
 *
 * Entries are sliced rather than assigned wholesale to their start day: a timer
 * left running overnight belongs partly to each day it crossed, and bucketing
 * it by start alone would credit tonight's hours to yesterday.
 *
 * Returns milliseconds — Dart returns a Duration, and JS has no equivalent, so
 * the unit is stated in the name of every consumer rather than being implied.
 */
export function overlapWithinMs(
  e: TimeEntry,
  from: Date,
  to: Date,
  now: Date,
): number {
  /* Capped, not `endedAt ?? now`. This is the line that stops a timer left
   * running over a weekend from posting 60 hours to Monday's dashboard — and
   * it has to be here rather than only in the display, because the dashboard
   * sums entries itself and would otherwise disagree with the board about the
   * same task. */
  const end = effectiveEnd(e, now);
  const lo = e.startedAt > from ? e.startedAt : from;
  const hi = end < to ? end : to;
  const ms = hi.getTime() - lo.getTime();
  return ms < 0 ? 0 : ms;
}
