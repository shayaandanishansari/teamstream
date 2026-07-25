/// <reference path="../pb_data/types.d.ts" />

// TeamStream — append-only change log ("history").
// Populated server-side by backend/pb_hooks/history.pb.js on every
// create/update/delete. The app can READ it (list/view open), but cannot
// create/edit/delete entries — the hook writes via superuser context, so the
// log is effectively append-only and tamper-resistant from the client.
migrate((app) => {
  const history = new Collection({
    type: "base",
    name: "history",
    // Readable only by an authenticated member (same shared-password gate as the
    // rest of the app); create/update/delete left null => superuser/hook-only.
    listRule: "@request.auth.id != ''",
    viewRule: "@request.auth.id != ''",
    fields: [
      { name: "collection", type: "text", required: true, max: 60 },
      { name: "record", type: "text", required: true, max: 60 },
      { name: "action", type: "text", required: true, max: 20 },
      { name: "actor_id", type: "text", max: 60 },
      { name: "actor_name", type: "text", max: 60 },
      { name: "before", type: "json", maxSize: 2000000 },
      { name: "after", type: "json", maxSize: 2000000 },
      { name: "ts", type: "date" },
    ],
  });
  app.save(history);
}, (app) => {
  try {
    app.delete(app.findCollectionByNameOrId("history"));
  } catch (e) {}
});
