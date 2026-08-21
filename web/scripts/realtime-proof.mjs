/* Phase 2's gate: prove PocketBase realtime + shared-password auth from JS.
 * plan.md: "STOP HERE if realtime misbehaves." Throwaway; delete after. */
import PocketBase from "pocketbase";

const URL = "http://127.0.0.1:8090";
const PW = "teamstream-dev-local";
const log = (...a) => console.log(new Date().toISOString().slice(11, 23), ...a);

// Two independent clients: one watching, one writing. A single client can be
// fooled by its own local state, so the write must come from somewhere else.
const watcher = new PocketBase(URL);
const writer = new PocketBase(URL);

const me = await watcher.collection("members").authWithPassword("shayaan@teamstream.local", PW);
await writer.collection("members").authWithPassword("umair@teamstream.local", PW);
log("auth ok:", me.record.name, "/ writer:", writer.authStore.record.name);

const seen = [];
const wait = (pred, ms = 5000) =>
  new Promise((res, rej) => {
    const t = setTimeout(() => rej(new Error("timed out waiting for " + pred.name)), ms);
    const tick = setInterval(() => {
      const hit = seen.find(pred);
      if (hit) { clearTimeout(t); clearInterval(tick); res(hit); }
    }, 25);
  });

for (const c of ["works", "tasks", "time_entries"]) {
  await watcher.collection(c).subscribe("*", (e) => {
    seen.push({ c, action: e.action, id: e.record.id, rec: e.record });
    log("  <- event", c, e.action, e.record.id);
  });
}
log("subscribed to works, tasks, time_entries");

const actor = { "X-Actor-Id": writer.authStore.record.id, "X-Actor-Name": "Umair" };
const w = await writer.collection("works").create(
  { title: "Realtime proof", position: Date.now(), archived: false }, { headers: actor });
log("created work", w.id);
await wait(function workCreate(e) { return e.c === "works" && e.action === "create" && e.id === w.id; });

const t = await writer.collection("tasks").create(
  { work: w.id, title: "prove it", position: Date.now(), is_done: false,
    is_archived: false, critical: false, note: "" }, { headers: actor });
await wait(function taskCreate(e) { return e.c === "tasks" && e.action === "create" && e.id === t.id; });

const started = new Date();
const en = await writer.collection("time_entries").create(
  { task: t.id, member: writer.authStore.record.id,
    started_at: started.toISOString(), ended_at: "" }, { headers: actor });
const ev = await wait(function entryCreate(e) { return e.c === "time_entries" && e.action === "create" && e.id === en.id; });
log("   live entry ended_at =", JSON.stringify(ev.rec.ended_at), "(empty string means LIVE)");

await writer.collection("time_entries").update(en.id, { ended_at: new Date().toISOString() }, { headers: actor });
await wait(function entryUpdate(e) { return e.c === "time_entries" && e.action === "update" && e.id === en.id; });

await writer.collection("works").delete(w.id, { headers: actor });
// works -> tasks -> time_entries all cascade; only the work's own delete event is guaranteed.
await wait(function workDelete(e) { return e.c === "works" && e.action === "delete" && e.id === w.id; });

// Does the server-side history hook fire, and does it carry our actor?
const hist = await watcher.collection("history").getList(1, 5, { sort: "-ts" });
log("history rows:", hist.totalItems, "| newest:", hist.items.map(h => `${h.collection}/${h.action} by ${h.actor_name || "(none)"}`).join(", "));

log("");
log("RESULT: create, update and delete all arrived over SSE. Auth + realtime OK.");
await watcher.collection("works").unsubscribe();
process.exit(0);
