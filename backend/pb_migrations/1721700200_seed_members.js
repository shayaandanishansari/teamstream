/// <reference path="../pb_data/types.d.ts" />

// TeamStream — seed the 3 members so a FRESH deploy comes up usable.
// (In dev these were entered by hand; a clean pb_data on the Linux box would
// otherwise have an empty members table and an empty name-picker.)
// Colors are the agreed palette. Idempotent: skips any name that already
// exists, so it's safe even against a copied dev database.
migrate((app) => {
  const seed = [
    { name: "Shayaan", color: "#00A896" }, // teal
    { name: "Umair",   color: "#FFB238" }, // amber
    { name: "Tawab",   color: "#3A5AFF" }, // cobalt
  ];
  const members = app.findCollectionByNameOrId("members");
  for (const m of seed) {
    try {
      app.findFirstRecordByFilter("members", "name = {:n}", { n: m.name });
      continue; // already present -> leave it alone
    } catch (_) { /* not found -> create it */ }
    const rec = new Record(members);
    rec.set("name", m.name);
    rec.set("color", m.color);
    app.save(rec);
  }
}, (app) => {
  for (const name of ["Shayaan", "Umair", "Tawab"]) {
    try {
      const rec = app.findFirstRecordByFilter("members", "name = {:n}", { n: name });
      app.delete(rec);
    } catch (_) {}
  }
});
