import type { RecordModel } from "pocketbase";
import { pb } from "./pb";
import { getState, set, update, reportWriteError } from "./store";
import { toMember } from "../models/member";
import { toWork } from "../models/work";
import { toTask } from "../models/task";
import { toTimeEntry } from "../models/timeEntry";
import { toAttachment } from "../models/attachment";
import { toFileRec } from "../models/fileRec";

/* The sync engine: server truth, an optimistic overlay, and realtime.
 *
 * TWO THINGS ARE DONE DIFFERENTLY FROM THE DART, both deliberate.
 *
 * 1. EVENTS ARE APPLIED, NOT USED AS A DOORBELL.
 *    pocketbase_repo.dart:104-128 subscribes with `(_) => load()` — it throws
 *    the event payload away and re-fetches the ENTIRE collection on every event
 *    of every kind. That is fine on day one and gets worse forever: time_entries
 *    grows by roughly 11k rows a year for three people, so today's design
 *    re-downloads every session anyone has ever logged each time somebody
 *    touches a timer. Here the event's own record is applied to a Map.
 *
 * 2. SUBSCRIBE FIRST, THEN LOAD.
 *    The Dart loads then subscribes, which drops anything created in the gap.
 *    It gets away with it because the very next event triggers a full refetch
 *    that heals the hole. Applying deltas removes that accidental safety net,
 *    so the order has to be right and the gap has to be buffered.
 */

export type Key = "members" | "works" | "tasks" | "entries" | "attachments" | "files";

interface Spec {
  collection: string;
  map: (r: RecordModel) => { id: string };
}

const SPECS: Record<Key, Spec> = {
  members: { collection: "members", map: toMember },
  works: { collection: "works", map: toWork },
  tasks: { collection: "tasks", map: toTask },
  entries: { collection: "time_entries", map: toTimeEntry },
  attachments: { collection: "attachments", map: toAttachment },
  files: { collection: "files", map: toFileRec },
};

const KEYS = Object.keys(SPECS) as Key[];

/* Server truth and the optimistic overlay live OUTSIDE React state.
 *
 * The store holds the merged arrays that components render; these hold the two
 * inputs that produce them. Keeping the bookkeeping out of the store means a
 * component can never see a half-merged view. */
const server = new Map<Key, Map<string, { id: string }>>();
const localUpserts = new Map<Key, Map<string, { id: string }>>();
const localDeletes = new Map<Key, Set<string>>();

for (const k of KEYS) {
  server.set(k, new Map());
  localUpserts.set(k, new Map());
  localDeletes.set(k, new Set());
}

/** Merge server truth with the overlay and hand the result to the store. */
function publish(key: Key): void {
  const byId = new Map(server.get(key)!);
  for (const [id, rec] of localUpserts.get(key)!) byId.set(id, rec);
  for (const id of localDeletes.get(key)!) byId.delete(id);
  set({ [key]: [...byId.values()] } as unknown as Record<string, never>);
}

function applyDelta(key: Key, action: string, record: RecordModel): void {
  const truth = server.get(key)!;
  if (action === "delete") truth.delete(record.id);
  else truth.set(record.id, SPECS[key].map(record));
  publish(key);
}

const unsubs: Array<() => void> = [];

async function syncCollection(key: Key): Promise<void> {
  const { collection, map } = SPECS[key];

  /* Buffer anything that arrives while the first page is still in flight. A
   * task created in that window would otherwise be invisible until the next
   * unrelated event — and with deltas there is no full refetch to paper over
   * it. */
  const buffered: Array<{ action: string; record: RecordModel }> = [];
  let loaded = false;

  const unsub = await pb.collection(collection).subscribe("*", (e) => {
    if (!loaded) buffered.push({ action: e.action, record: e.record });
    else applyDelta(key, e.action, e.record);
  });
  unsubs.push(unsub);

  const rows = await pb.collection(collection).getFullList();
  server.set(key, new Map(rows.map((r) => [r.id, map(r)])));
  loaded = true;

  // Replaying is safe in either direction: everything is keyed by id, so a
  // buffered create the load also returned just overwrites itself.
  for (const e of buffered) applyDelta(key, e.action, e.record);
  publish(key);
}

/** Load everything and open the realtime subscriptions. */
export async function startSync(): Promise<void> {
  try {
    await Promise.all(KEYS.map(syncCollection));
    set({ booted: true, fatal: null });
  } catch (err) {
    set({ booted: true, fatal: describe(err) });
  }
}

export async function stopSync(): Promise<void> {
  await Promise.allSettled(unsubs.map((u) => u()));
  unsubs.length = 0;
  for (const k of KEYS) {
    server.get(k)!.clear();
    localUpserts.get(k)!.clear();
    localDeletes.get(k)!.clear();
  }
}

/* ---- optimistic writes -------------------------------------------------- */

export function describe(err: unknown): string {
  if (err && typeof err === "object") {
    const e = err as { message?: string; status?: number };
    if (e.status === 0) return "The server is unreachable.";
    if (e.message) return e.message;
  }
  return "Something went wrong.";
}

let tmpCounter = 0;
export const tempId = (): string => `tmp_${++tmpCounter}`;

/* Every optimistic write follows the same three beats: show it, send it, then
 * either adopt the server's version of it or put things back.
 *
 * Adopting the ACK is what makes this simpler than optimistic_repo.dart, which
 * carries a third `_settled` set to remember which optimistic values may be
 * dropped once a fresh server snapshot arrives. PocketBase's create and update
 * calls already RETURN the saved record — the Dart throws that away and waits
 * for realtime to bring it back. Writing it straight into server truth means
 * the overlay can be dropped immediately, with no window where the UI flickers
 * back to the old value between the ack and the SSE event, and no third set to
 * keep consistent.
 *
 * Nothing here rethrows. A failed write surfaces as a rollback plus one line in
 * `state.errors` — the same contract as the Dart's writeErrors stream, and the
 * reason no call site needs a try/catch. */
async function optimistic(
  key: Key,
  show: () => string,
  send: () => Promise<RecordModel | null>,
  undo: (id: string) => void,
): Promise<{ id: string } | null> {
  const id = show();
  publish(key);
  update((s) => ({ pending: s.pending + 1 }));
  try {
    const saved = await send();
    localUpserts.get(key)!.delete(id);
    localDeletes.get(key)!.delete(id);
    let mapped: { id: string } | null = null;
    if (saved) {
      mapped = SPECS[key].map(saved);
      server.get(key)!.set(saved.id, mapped);
    }
    publish(key);
    return mapped;
  } catch (err) {
    undo(id);
    publish(key);
    reportWriteError(describe(err));
    return null;
  } finally {
    update((s) => ({ pending: Math.max(0, s.pending - 1) }));
  }
}

export function optimisticCreate<T extends { id: string }>(
  key: Key,
  placeholder: T,
  send: () => Promise<RecordModel>,
): Promise<T | null> {
  return optimistic(
    key,
    () => {
      localUpserts.get(key)!.set(placeholder.id, placeholder);
      return placeholder.id;
    },
    send,
    (id) => {
      localUpserts.get(key)!.delete(id);
    },
  ) as Promise<T | null>;
}

export function optimisticUpdate<T extends { id: string }>(
  key: Key,
  id: string,
  patched: T,
  send: () => Promise<RecordModel>,
): Promise<T | null> {
  return optimistic(
    key,
    () => {
      localUpserts.get(key)!.set(id, patched);
      return id;
    },
    send,
    (i) => {
      localUpserts.get(key)!.delete(i);
    },
  ) as Promise<T | null>;
}

/* Deleting a work or a task cascades on the server, and the realtime events for
 * the children DO arrive (verified — scripts/realtime-proof.mjs watches them).
 * So unlike optimistic_repo.dart, which mirrors the cascade by hand across
 * three collections, the only thing to hide locally is the row itself; the
 * children disappear when their own events land a few milliseconds later.
 *
 * `extraKeys` exists for the one case where that lag is visible: a task's rows
 * in the board's own totals. Pass the collections whose children should be
 * hidden immediately too. */
export function optimisticDelete(
  key: Key,
  id: string,
  send: () => Promise<boolean>,
  alsoHide: Array<{ key: Key; ids: string[] }> = [],
): Promise<null> {
  for (const { key: k, ids } of alsoHide) {
    for (const i of ids) localDeletes.get(k)!.add(i);
    publish(k);
  }
  return optimistic(
    key,
    () => {
      localDeletes.get(key)!.add(id);
      return id;
    },
    async () => {
      await send();
      server.get(key)!.delete(id);
      // The server cascaded; drop the children from truth and stop hiding them.
      for (const { key: k, ids } of alsoHide) {
        for (const i of ids) {
          server.get(k)!.delete(i);
          localDeletes.get(k)!.delete(i);
        }
        publish(k);
      }
      return null;
    },
    (i) => {
      localDeletes.get(key)!.delete(i);
      for (const { key: k, ids } of alsoHide) {
        for (const x of ids) localDeletes.get(k)!.delete(x);
        publish(k);
      }
    },
  ) as Promise<null>;
}

/** The current merged view of one collection, without going through React. */
export const currentView = <T,>(key: Key): T[] => getState()[key] as T[];
