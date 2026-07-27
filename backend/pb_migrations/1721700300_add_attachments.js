/// <reference path="../pb_data/types.d.ts" />

// TeamStream — file attachments on tasks.
//
// A note is one string on the task; an attachment is a record, so a task can
// carry many and each one remembers WHO put it there. That authorship is the
// point: the board renders attachments one member per row, the same way the
// dots already show who spent time.
//
// `file` is NOT protected. Protected files need a short-lived token appended to
// every URL, which would break `<img>` previews as soon as the token expires
// (minutes). The URLs contain PocketBase's random record id plus a randomised
// filename suffix, so they're unguessable, and the app itself is already behind
// the shared password. Trade-off accepted for the same reason as the rest of
// this design: three trusted people, no ceremony.
migrate((app) => {
  const authed = "@request.auth.id != ''";
  const tasks = app.findCollectionByNameOrId("tasks");
  const members = app.findCollectionByNameOrId("members");

  const attachments = new Collection({
    type: "base",
    name: "attachments",
    listRule: authed,
    viewRule: authed,
    createRule: authed,
    updateRule: authed,
    deleteRule: authed,
    fields: [
      { name: "task", type: "relation", required: true, collectionId: tasks.id, maxSelect: 1, cascadeDelete: true },
      { name: "member", type: "relation", required: true, collectionId: members.id, maxSelect: 1, cascadeDelete: true },
      // `thumbs` must list every size the app may ask for — PocketBase serves
      // the full-size original for anything not declared here, which on a board
      // full of phone photos would be megabytes per tile.
      { name: "file", type: "file", required: true, maxSelect: 1, maxSize: 20971520, thumbs: ["240x240"] },
      // The original filename. PocketBase randomises the stored name, so
      // without this the board would show "photo_a8Fq2.jpg" instead of what the
      // person actually picked.
      { name: "name", type: "text", required: true, max: 255 },
      { name: "size", type: "number" },
      { name: "created", type: "autodate", onCreate: true, onUpdate: false },
    ],
  });
  app.save(attachments);
}, (app) => {
  try { app.delete(app.findCollectionByNameOrId("attachments")); } catch (e) {}
});
