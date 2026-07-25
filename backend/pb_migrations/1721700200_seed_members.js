/// <reference path="../pb_data/types.d.ts" />

// TeamStream — seed the 3 members as AUTH accounts sharing ONE password.
//
// The password comes from the TEAMSTREAM_PASSWORD env var at migrate time; if
// unset it falls back to a placeholder you MUST change. Set it before the first
// `migrate up`, e.g.:  TEAMSTREAM_PASSWORD='the-shared-secret' ./pocketbase migrate up
//
// Login identity is the email, derived from the name (shayaan@teamstream.local);
// users only ever tap a name + type the shared password — they never see the email.
// Idempotent: skips any member whose email already exists.
migrate((app) => {
  const pw = $os.getenv("TEAMSTREAM_PASSWORD") || "teamstream-changeme";
  const seed = [
    { name: "Shayaan", color: "#00A896" }, // teal
    { name: "Umair",   color: "#FFB238" }, // amber
    { name: "Tawab",   color: "#3A5AFF" }, // cobalt
  ];
  const members = app.findCollectionByNameOrId("members");
  for (const m of seed) {
    const email = m.name.toLowerCase() + "@teamstream.local";
    try {
      app.findAuthRecordByEmail("members", email);
      continue; // already present -> leave it alone
    } catch (_) { /* not found -> create it */ }
    const rec = new Record(members);
    rec.set("email", email);
    rec.set("emailVisibility", false);
    rec.set("verified", true);
    rec.set("name", m.name);
    rec.set("color", m.color);
    rec.setPassword(pw);
    app.save(rec);
  }
}, (app) => {
  for (const name of ["Shayaan", "Umair", "Tawab"]) {
    try {
      const rec = app.findAuthRecordByEmail("members", name.toLowerCase() + "@teamstream.local");
      app.delete(rec);
    } catch (_) {}
  }
});
