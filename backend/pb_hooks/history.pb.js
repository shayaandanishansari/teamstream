/// <reference path="../pb_data/types.d.ts" />

// TeamStream — append-only history capture.
//
// IMPORTANT: PocketBase runs each hook handler in an ISOLATED scope — a handler
// CANNOT see functions/consts declared at the top of this file. So each handler
// below is fully self-contained (no shared helpers).
//
// Records every create/update/delete on the data collections into `history`,
// with full before/after snapshots, so anything can be revived. Runs on the
// request lifecycle, capturing changes from the app AND the admin UI alike.
//
// Actor comes from headers the client sends on each write:
//   X-Actor-Id / X-Actor-Name  ->  requestInfo().headers.x_actor_id / x_actor_name

onRecordCreateRequest((e) => {
  e.next();
  try {
    const h = e.requestInfo().headers;
    $app.save(new Record($app.findCollectionByNameOrId("history"), {
      collection: e.record.collection().name,
      record: e.record.id,
      action: "create",
      actor_id: (h && h["x_actor_id"]) || "",
      actor_name: (h && h["x_actor_name"]) || "",
      before: null,
      after: e.record.publicExport(),
      ts: new Date().toISOString(),
    }));
  } catch (err) {
    console.log("[history] create log failed:", err);
  }
}, "works", "tasks", "time_entries", "events", "attachments");

onRecordUpdateRequest((e) => {
  let before = null;
  try {
    before = e.record.original().publicExport();
  } catch (err) {}
  const cn = e.record.collection().name;
  const id = e.record.id;
  e.next();
  try {
    const h = e.requestInfo().headers;
    $app.save(new Record($app.findCollectionByNameOrId("history"), {
      collection: cn,
      record: id,
      action: "update",
      actor_id: (h && h["x_actor_id"]) || "",
      actor_name: (h && h["x_actor_name"]) || "",
      before: before,
      after: e.record.publicExport(),
      ts: new Date().toISOString(),
    }));
  } catch (err) {
    console.log("[history] update log failed:", err);
  }
}, "works", "tasks", "time_entries", "events", "attachments");

onRecordDeleteRequest((e) => {
  const cn = e.record.collection().name;
  const id = e.record.id;
  let before = null;
  try {
    before = e.record.publicExport();
  } catch (err) {}
  const h = e.requestInfo().headers;
  const actorId = (h && h["x_actor_id"]) || "";
  const actorName = (h && h["x_actor_name"]) || "";
  e.next();
  try {
    $app.save(new Record($app.findCollectionByNameOrId("history"), {
      collection: cn,
      record: id,
      action: "delete",
      actor_id: actorId,
      actor_name: actorName,
      before: before,
      after: null,
      ts: new Date().toISOString(),
    }));
  } catch (err) {
    console.log("[history] delete log failed:", err);
  }
}, "works", "tasks", "time_entries", "events", "attachments");
