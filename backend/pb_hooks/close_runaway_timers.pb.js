/// <reference path="../pb_data/types.d.ts" />

// TeamStream — close timers nobody stopped.
//
// A timer left running closes itself after three hours. The client does the
// same thing (web/src/data/actions.ts, closeExpiredTimers), but a browser can
// only close a timer while a browser is open — close the laptop on a Friday and
// nothing is awake to notice. This is what makes the rule true when nobody is
// looking.
//
// IT WRITES `started_at + 3h`, NOT `now`, and that is the whole subtlety.
// `effectiveEnd` in web/src/models/timeMath.ts already treats a live entry as
// ending at start+3h, so the board and the dashboard have been showing the
// capped number all along. Writing `now` here would bank six hours the moment
// this ran on a timer left going overnight — a number that had been stable for
// hours would suddenly jump. Both sides write the same value, so it does not
// matter which of them gets there first.
//
// IMPORTANT: PocketBase runs each hook handler in an ISOLATED scope. A handler
// CANNOT see anything declared at the top of this file — which is why
// history.pb.js copy-pastes three near-identical handlers instead of sharing a
// helper, and why every constant below lives inside the closure.
cronAdd("close_runaway_timers", "*/10 * * * *", () => {
  // Mirrors MAX_SESSION_MS in web/src/models/timeMath.ts. Duplicated because of
  // the isolated-scope rule above; if one changes, change both.
  const MAX_MS = 3 * 60 * 60 * 1000;

  // Every ten minutes, not every minute. The arithmetic is already capped on
  // the client, so a row that is up to ten minutes stale changes no number
  // anybody can see; the only visible effect is the "live" pill going out, and
  // that should happen within a coffee break of the cap rather than within an
  // hour.
  //
  // THE `.replace("T", " ")` IS LOAD-BEARING. Do not "tidy" it away.
  //
  // PocketBase stores dates as "YYYY-MM-DD HH:MM:SS.sssZ" — a space where ISO
  // 8601 puts a T — and compares this filter LEXICOGRAPHICALLY against that
  // stored text. A cutoff built with toISOString() carries a "T" at index 10,
  // and ' ' (0x20) sorts below 'T' (0x54), so EVERY stored timestamp with the
  // same date compares as "<= cutoff" no matter what time it says.
  //
  // The bug that causes is not subtle in effect, only in appearance: the sweep
  // closes every live timer started today, every ten minutes, writing a plausible
  // start+3h onto each one. It was caught by a fixture that asserted a
  // two-hour-old timer stays open — see the note in DEPLOY.md.
  const cutoff = new Date(Date.now() - MAX_MS).toISOString().replace("T", " ");

  let rows = [];
  try {
    // `ended_at = ''` is how PocketBase spells an unset date — it stores an
    // empty string, not SQL NULL. This is the same predicate the app relies on
    // for "LIVE right now".
    rows = $app.findRecordsByFilter(
      "time_entries",
      "ended_at = '' && started_at <= {:cutoff}",
      "started_at", // oldest first
      200,          // bounded, so one bad night cannot run for minutes
      0,
      { cutoff: cutoff },
    );
  } catch (err) {
    console.log("[3h-cap] query failed:", err);
    return;
  }

  let closed = 0;
  for (const r of rows) {
    try {
      // PocketBase hands dates back as "YYYY-MM-DD HH:MM:SS.sssZ" — a space
      // rather than a T, which Date.parse will not reliably take.
      const startedRaw = r.getDateTime("started_at").string();
      const startedMs = Date.parse(startedRaw.replace(" ", "T"));
      if (!startedMs) {
        continue;
      }

      const before = r.publicExport();
      r.set("ended_at", new Date(startedMs + MAX_MS).toISOString());
      $app.save(r);
      closed++;

      // history.pb.js binds onRecord*Request, and a cron save is not a request,
      // so nothing else logs this. Without it a time entry would silently
      // change value with a gap in the log at exactly the point where an
      // automated writer touched somebody's hours.
      //
      // The alternative — binding the model-level onRecordUpdate, which does
      // fire for hook-side saves — was rejected: every request-side edit would
      // then fire both hooks and write TWO history rows, so fixing this one new
      // path would change the behaviour of every existing one.
      try {
        $app.save(new Record($app.findCollectionByNameOrId("history"), {
          collection: "time_entries",
          record: r.id,
          action: "update",
          actor_id: "",
          actor_name: "system (3h cap)",
          before: before,
          after: r.publicExport(),
          ts: new Date().toISOString(),
        }));
      } catch (err) {
        // Logged after the entry is already saved, so a history failure can
        // never leave a timer running.
        console.log("[3h-cap] history log failed:", err);
      }
    } catch (err) {
      console.log("[3h-cap] could not close", r && r.id, err);
    }
  }

  if (closed) {
    console.log("[3h-cap] closed " + closed + " timer(s)");
  }
});
