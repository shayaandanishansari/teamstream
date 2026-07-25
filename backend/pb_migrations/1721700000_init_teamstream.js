/// <reference path="../pb_data/types.d.ts" />

// TeamStream initial schema — 5 collections.
// Access rules are open ("") on purpose: the whole backend lives behind a
// private, self-hosted setup for a 3-person trusted team (no per-user auth).
migrate((app) => {
  const open = { listRule: "", viewRule: "", createRule: "", updateRule: "", deleteRule: "" };

  // 1. members — the 3 people (seeded separately once we know the names)
  const members = new Collection({
    type: "base",
    name: "members",
    ...open,
    fields: [
      { name: "name", type: "text", required: true, max: 50 },
      { name: "color", type: "text", max: 20 },
    ],
  });
  app.save(members);

  // 2. works — projects; state + sort-order are DERIVED from child tasks
  const works = new Collection({
    type: "base",
    name: "works",
    ...open,
    fields: [
      { name: "title", type: "text", required: true, max: 120 },
      { name: "position", type: "number" },
      { name: "archived", type: "bool" },
    ],
  });
  app.save(works);

  // 3. tasks — the durable unit
  const tasks = new Collection({
    type: "base",
    name: "tasks",
    ...open,
    fields: [
      { name: "work", type: "relation", required: true, collectionId: works.id, maxSelect: 1, cascadeDelete: true },
      { name: "title", type: "text", required: true, max: 200 },
      { name: "is_done", type: "bool" },
      { name: "done_at", type: "date" },
      { name: "is_archived", type: "bool" },
      { name: "note", type: "text", max: 500 },
      { name: "due_date", type: "date" },
      { name: "critical", type: "bool" },
      { name: "position", type: "number" },
    ],
  });
  app.save(tasks);

  // 4. time_entries — the core mechanism. ended_at == null means LIVE right now.
  const timeEntries = new Collection({
    type: "base",
    name: "time_entries",
    ...open,
    fields: [
      { name: "task", type: "relation", required: true, collectionId: tasks.id, maxSelect: 1, cascadeDelete: true },
      { name: "member", type: "relation", required: true, collectionId: members.id, maxSelect: 1, cascadeDelete: true },
      { name: "started_at", type: "date", required: true },
      { name: "ended_at", type: "date" },
    ],
  });
  app.save(timeEntries);

  // 5. events — standalone calendar items (task deadlines come from tasks.due_date)
  const events = new Collection({
    type: "base",
    name: "events",
    ...open,
    fields: [
      { name: "title", type: "text", required: true, max: 200 },
      { name: "date", type: "date", required: true },
      { name: "all_day", type: "bool" },
      { name: "note", type: "text", max: 500 },
      { name: "task", type: "relation", collectionId: tasks.id, maxSelect: 1, cascadeDelete: false },
    ],
  });
  app.save(events);
}, (app) => {
  // rollback — delete in reverse dependency order
  ["events", "time_entries", "tasks", "works", "members"].forEach((n) => {
    try { app.delete(app.findCollectionByNameOrId(n)); } catch (e) {}
  });
});
