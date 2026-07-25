/// <reference path="../pb_data/types.d.ts" />

// TeamStream initial schema — 5 collections.
// Access model: a single SHARED PASSWORD gates the whole app.
//  - `members` is an AUTH collection (the 3 accounts are pre-created in the seed
//    migration, all sharing one password). Its name+color are readable WITHOUT
//    auth so the login screen can show who to sign in as; emails stay hidden.
//  - Every DATA collection (works/tasks/time_entries/events) requires an
//    authenticated request (`@request.auth.id != ''`).
// The login identity is the member's email, derived internally from their name
// (e.g. shayaan@teamstream.local). Users never see it — they tap their name and
// type the shared password.
migrate((app) => {
  const authed = "@request.auth.id != ''";
  const rw = { listRule: authed, viewRule: authed, createRule: authed, updateRule: authed, deleteRule: authed };

  // 1. members — the 3 people AND the auth accounts (shared password).
  const members = new Collection({
    type: "auth",
    name: "members",
    listRule: "",      // names + colors readable pre-auth (for the login picker)
    viewRule: "",
    createRule: null,  // no self-registration; seeded + superuser-managed only
    updateRule: null,
    deleteRule: null,
    passwordAuth: { enabled: true, identityFields: ["email"] },
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
    ...rw,
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
    ...rw,
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
    ...rw,
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
    ...rw,
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
