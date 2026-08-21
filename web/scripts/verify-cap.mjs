/* Verify the three-hour cap end to end, against a real PocketBase.
 *
 *   node --experimental-eventsource scripts/verify-cap.mjs
 *
 * This exists because the sweep hook shipped a bug that no unit test could have
 * caught: PocketBase stores dates as "YYYY-MM-DD HH:MM:SS.sssZ" and compares
 * filters lexicographically, so a cutoff built with toISOString() — which puts
 * a "T" where the stored format has a space — made every timestamp from the
 * same date compare as older than the cutoff. The sweep closed EVERY live timer
 * started today, every ten minutes, and wrote a perfectly plausible start+3h
 * onto each one. The only thing that catches that is a fixture asserting a
 * two-hour-old timer is still running afterwards.
 *
 * Needs the dev superuser, because triggering a cron on demand is a superuser
 * route. Set up in DEPLOY.md; defaults below match the local dev database.
 */
import PocketBase from "pocketbase";

const URL = process.env.TS_PB_URL ?? "http://127.0.0.1:8090";
const MEMBER_PW = process.env.TS_DEV_PASSWORD ?? "teamstream-dev-local";
const SU_EMAIL = process.env.TS_SU_EMAIL ?? "dev@teamstream.local";
const SU_PW = process.env.TS_SU_PASSWORD ?? "devpassword123";
const HOUR = 3600_000;

let failures = 0;
const check = (label, ok, detail = "") => {
  console.log(`${ok ? "  ok  " : "  FAIL"}  ${label}${detail ? `  — ${detail}` : ""}`);
  if (!ok) failures++;
};

/** PocketBase hands dates back with a space instead of a T. */
const parse = (s) => new Date(String(s).replace(" ", "T"));

const pb = new PocketBase(URL);
const su = new PocketBase(URL);

const me = await pb.collection("members").authWithPassword("shayaan@teamstream.local", MEMBER_PW);
await su.collection("_superusers").authWithPassword(SU_EMAIL, SU_PW);
const H = { headers: { "X-Actor-Id": me.record.id, "X-Actor-Name": me.record.name } };

const ago = (h) => new Date(Date.now() - h * HOUR).toISOString();
const work = await pb.collection("works").create(
  { title: "3h cap fixture", position: Date.now(), archived: false }, H);
const task = await pb.collection("tasks").create(
  { work: work.id, title: "fixture", position: Date.now(),
    is_done: false, is_archived: false, critical: false, note: "" }, H);
const mk = (started, ended) =>
  pb.collection("time_entries").create(
    { task: task.id, member: me.record.id, started_at: started, ended_at: ended }, H);

try {
  const runaway = await mk(ago(4), "");        // open, 4h — must be closed
  const young = await mk(ago(2), "");          // open, 2h — must be LEFT ALONE
  const stopped = await mk(ago(5), ago(1));    // 4h long, but a person stopped it
  const stoppedEndedAt = stopped.ended_at;

  console.log("\ntriggering close_runaway_timers…");
  const res = await fetch(`${URL}/api/crons/close_runaway_timers`, {
    method: "POST",
    headers: { Authorization: su.authStore.token },
  });
  check("cron ran", res.status === 204, `HTTP ${res.status}`);

  /* The trigger returns 204 as soon as the job is DISPATCHED, not when it has
   * finished — reading straight after it is a race, and the first version of
   * this script lost it about half the time. Poll for the effect instead. */
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    const probe = await pb.collection("time_entries").getOne(runaway.id);
    if (probe.ended_at !== "") break;
    await new Promise((r) => setTimeout(r, 100));
  }

  const after = async (id) => pb.collection("time_entries").getOne(id);
  const a = await after(runaway.id);
  const b = await after(young.id);
  const c = await after(stopped.id);

  check("a runaway timer gets closed", a.ended_at !== "");
  if (a.ended_at !== "") {
    const ms = parse(a.ended_at) - parse(a.started_at);
    check("…to exactly started_at + 3h", ms === 3 * HOUR, `got ${ms / HOUR}h`);
    const driftFromNow = Math.abs(parse(a.ended_at) - Date.now());
    check("…and NOT to now", driftFromNow > 30 * 60_000,
      `ended_at is ${Math.round(driftFromNow / 60000)}min from now`);
  }

  // The assertion that catches the lexicographic-compare bug.
  check("a two-hour-old timer is left running", b.ended_at === "",
    b.ended_at === "" ? "" : `it was closed to ${b.ended_at}`);

  // The cap applies only to entries nobody stopped. An entry with an ended_at
  // is a person having pressed stop, and that is the truth about their day —
  // capping it would silently delete an hour from someone who worked four.
  check("an entry a person stopped is untouched", c.ended_at === stoppedEndedAt,
    c.ended_at === stoppedEndedAt ? "" : `${stoppedEndedAt} -> ${c.ended_at}`);

  const hist = await pb.collection("history").getList(1, 5, {
    sort: "-ts",
    filter: `record="${runaway.id}"`,
  });
  // A cron save is not a request, so history.pb.js does not see it. The hook
  // writes its own row, or a timer would change value with a gap in the log.
  check("the sweep logged itself to history",
    hist.items.some((h) => h.actor_name === "system (3h cap)"),
    hist.items.map((h) => h.actor_name || "(none)").join(", "));
} finally {
  await pb.collection("works").delete(work.id, H); // cascades to task + entries
}

console.log(failures === 0 ? "\nAll cap checks passed.\n" : `\n${failures} FAILED\n`);
/* Close the realtime connection before exiting. Without this, Node on Windows
 * tears down an open EventSource handle during process.exit and libuv prints an
 * assertion failure AFTER the success line - a passing script that looks like it
 * crashed, which erodes trust in the suite faster than a failing one. */
await pb.realtime.unsubscribe().catch(() => {});
await su.realtime.unsubscribe().catch(() => {});
process.exitCode = failures === 0 ? 0 : 1;
