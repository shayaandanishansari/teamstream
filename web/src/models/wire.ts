/* Reading and writing PocketBase's wire format.
 *
 * The Dart app has no fromJson anywhere — every field name in the system is
 * spelled exactly once, in `app/lib/data/pocketbase_repo.dart`. The modules in
 * this directory are the port of that file's mapping half, and they are the
 * only place in the React app that knows what PocketBase calls anything.
 */

/** PocketBase sends dates as "2026-08-20 20:57:40.653Z" — a SPACE, not a `T`.
 *
 * V8 parses that shape, so it works in Chrome and in Node and would sail
 * through every test written on this machine. It is not ISO 8601, and Safari
 * has historically returned Invalid Date for it — which is the whole team,
 * since they run this as an Add-to-Home-Screen app on iPhones. Normalise once,
 * here, rather than discovering it on someone's phone.
 *
 * An empty string is PocketBase's "no value" for a date field, and it is
 * load-bearing: `ended_at == ""` is what "this timer is LIVE right now" means.
 */
export function readDate(v: unknown): Date | null {
  if (typeof v !== "string" || v === "") return null;
  const d = new Date(v.replace(" ", "T"));
  return Number.isNaN(d.getTime()) ? null : d;
}

/** Dates go out as UTC ISO, exactly as `_iso` does in the Dart. */
export const writeDate = (d: Date): string => d.toISOString();

/** Clearing a date sends `''`, NOT null.
 *
 * PocketBase stores an unset date as an empty string, and the Dart relies on
 * this in three places (`done_at` when a task is un-done, `due_date` when a due
 * date is removed, `ended_at` on a fresh entry). Sending null makes PocketBase
 * reject the write rather than clear the field, so the distinction is not
 * cosmetic. */
export const writeDateOrClear = (d: Date | null): string => (d === null ? "" : d.toISOString());

export const readStr = (v: unknown, fallback = ""): string =>
  typeof v === "string" ? v : fallback;

export const readNum = (v: unknown, fallback = 0): number =>
  typeof v === "number" && Number.isFinite(v) ? v : fallback;

export const readBool = (v: unknown): boolean => v === true;

/** A relation that is not set comes back as `''`, not null or undefined. */
export const readRel = (v: unknown): string | null => {
  const s = readStr(v);
  return s === "" ? null : s;
};
