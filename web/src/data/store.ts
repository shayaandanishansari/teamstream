import { useSyncExternalStore } from "react";
import type { Member } from "../models/member";
import type { Work } from "../models/work";
import type { Task } from "../models/task";
import type { TimeEntry } from "../models/timeEntry";
import type { Attachment } from "../models/attachment";
import type { FileRec } from "../models/fileRec";

/* One store — video_editor's CLAUDE.md rule, ported.
 *
 * The one thing changed in the port: this state is IMMUTABLE. video_editor's
 * store mutates a single module-level object with Object.assign and returns the
 * same identity forever, which is why only its root component may subscribe —
 * nothing below can compare props by reference, so every write re-renders the
 * whole tree. That is fine for a video editor with one screen and it is not
 * fine here. Replacing the object on every write means useSyncExternalStore can
 * do its job and React.memo actually works.
 *
 * Writes still coalesce onto a microtask, which is the part worth keeping: one
 * interaction that touches three fields renders once.
 */

export interface WriteError {
  id: number;
  message: string;
}

export interface AppState {
  /** null = we have not decided yet; false = show the login screen. */
  signedIn: boolean | null;
  me: Member | null;
  booted: boolean;
  fatal: string | null;

  members: Member[];
  works: Work[];
  tasks: Task[];
  entries: TimeEntry[];
  attachments: Attachment[];
  files: FileRec[];

  /** In-flight optimistic writes, for a subtle "saving" hint. */
  pending: number;
  /** Writes that failed and were rolled back. */
  errors: WriteError[];
}

const initial: AppState = {
  signedIn: null,
  me: null,
  booted: false,
  fatal: null,
  members: [],
  works: [],
  tasks: [],
  entries: [],
  attachments: [],
  files: [],
  pending: 0,
  errors: [],
};

let state: AppState = initial;
const listeners = new Set<() => void>();
let queued = false;

function flush() {
  queued = false;
  // Iterate a copy: a listener that unsubscribes mid-flush would otherwise
  // corrupt the iteration.
  for (const fn of [...listeners]) fn();
}

export const getState = (): AppState => state;

export function set(patch: Partial<AppState>): void {
  state = { ...state, ...patch };
  if (!queued) {
    queued = true;
    queueMicrotask(flush);
  }
}

/** Read-modify-write against the freshest state. `set` replaces synchronously,
 *  so several of these in one tick compose correctly and still render once. */
export function update(fn: (s: AppState) => Partial<AppState>): void {
  set(fn(state));
}

function subscribe(fn: () => void): () => void {
  listeners.add(fn);
  return () => { listeners.delete(fn); };
}

/* Returns the whole state object.
 *
 * Not a selector API on purpose: useSyncExternalStore requires the snapshot to
 * be referentially stable between renders, so a selector returning a fresh
 * array (`s.tasks.filter(...)`) would loop forever. The state object's identity
 * only changes on a real write, so this is stable by construction, and derived
 * lists belong in a useMemo in the component that wants them. */
export const useStore = (): AppState =>
  useSyncExternalStore(subscribe, getState, getState);

let nextErrorId = 1;
export function reportWriteError(message: string): void {
  update((s) => ({ errors: [...s.errors, { id: nextErrorId++, message }] }));
}
export function dismissWriteError(id: number): void {
  update((s) => ({ errors: s.errors.filter((e) => e.id !== id) }));
}

/** Back to a signed-out blank slate, keeping nothing from the last session. */
export function resetStore(): void {
  state = { ...initial, signedIn: false };
  queueMicrotask(flush);
}
