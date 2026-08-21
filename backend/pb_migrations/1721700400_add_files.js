/// <reference path="../pb_data/types.d.ts" />

// TeamStream — the shared drive.
//
// This is NOT a second copy of `attachments`, and the difference is the whole
// reason it is a separate collection:
//
//   attachments  a screenshot pinned to a task. Bytes live in PocketBase's own
//                file field, 20MB cap, cascadeDelete: true — deleting the task
//                takes the screenshot with it, which is right.
//   files        a shared drive. Bytes live under /srv/teamstream-files behind
//                the FastAPI service, no size cap, and NOTHING may destroy a
//                row through the API.
//
// There is no `file` field here. PocketBase owns the record and the identity;
// FastAPI owns the bytes. `file_id` is the join between them — minted by
// FastAPI when an upload starts, 26 lowercase base32 characters, never reused.
// That immutability is what lets the download and thumbnail URLs be cached as
// `immutable` for a year.
//
// TWO LINES CARRY THE ENTIRE DELETION POLICY, and both are easy to "tidy" away
// by someone who has not read this:
//
//   deleteRule: null
//     Not an oversight. "Never destroy anything" written in a design document
//     is a suggestion a tired person can talk themselves around at 1am; a null
//     rule is a mechanism that returns 403 to every client, to FastAPI, to a
//     stray curl and to the app itself, forever, with no code to maintain. The
//     `history` collection already makes exactly this move. The app's "delete"
//     is an UPDATE that sets `deleted_at`, which updateRule permits, and the
//     blob on disk is never touched at all. A superuser can still delete from
//     /_/ — which is correct: that is a deliberate act at a keyboard, and a
//     destructive operation should carry exactly that much ceremony.
//
//   cascadeDelete: false, on BOTH relations
//     `attachments` sets these true. Copying that here would be fatal, because
//     cascades run BELOW the API rules: deleting a member or a task would
//     silently destroy the very rows deleteRule exists to protect, and no rule
//     would ever be consulted. This is the highest-consequence line in the file.
migrate((app) => {
  const authed = "@request.auth.id != ''";
  const members = app.findCollectionByNameOrId("members");
  const tasks = app.findCollectionByNameOrId("tasks");

  const files = new Collection({
    type: "base",
    name: "files",

    listRule: authed,
    viewRule: authed,
    // The uploader is CHECKED, not claimed. FastAPI creates this record by
    // forwarding the caller's own member token rather than holding a superuser
    // credential, so PocketBase itself verifies that `member` is who is asking.
    // With a shared password, attribution is already the weakest link in the
    // system; it should not also be self-asserted by a service.
    createRule: authed + " && member = @request.auth.id",
    updateRule: authed,
    deleteRule: null,

    fields: [
      { name: "file_id", type: "text", required: true, max: 32, pattern: "^[0-9a-z]{26}$" },
      { name: "name", type: "text", required: true, max: 255 },
      // One flat string, not a tree. A folder plus a filter chip is 95% of the
      // value; nesting means rename, move and orphan handling — the layer this
      // project exists to avoid.
      { name: "folder", type: "text", max: 120 },
      // Float64 underneath, so exact to 2^53 bytes — 9PB. No cap field: the
      // decision was no hard limit, with a soft warning client-side and a 507
      // from the file service when the disk genuinely cannot take it.
      { name: "size", type: "number", required: true, onlyInt: true, min: 0 },
      // The SNIFFED type, decided server-side from the bytes. Never the type
      // the browser declared — an uploaded .html served inline from this origin
      // would be able to read the auth token out of localStorage.
      { name: "mime", type: "text", max: 160 },
      { name: "sha256", type: "text", max: 64 },
      { name: "member", type: "relation", required: true, collectionId: members.id, maxSelect: 1, cascadeDelete: false },
      // Optional: a drive file may also be pinned to a task. Still no cascade —
      // deleting the task must not reach into the drive.
      { name: "task", type: "relation", collectionId: tasks.id, maxSelect: 1, cascadeDelete: false },
      { name: "deleted_at", type: "date" },
      { name: "deleted_by", type: "relation", collectionId: members.id, maxSelect: 1, cascadeDelete: false },
      { name: "created", type: "autodate", onCreate: true, onUpdate: false },
      { name: "updated", type: "autodate", onCreate: true, onUpdate: true },
    ],

    // The first indexes in this database. Everything else has been unindexed
    // since day one, which is survivable for three people and a few hundred
    // rows and is not survivable for a drive that only ever grows.
    //
    // The unique one is not cosmetic: it is the last backstop that makes a
    // racing double-finish safe. If two requests somehow both try to record the
    // same upload, the second gets a constraint error instead of a duplicate.
    indexes: [
      "CREATE UNIQUE INDEX idx_files_file_id ON files (file_id)",
      "CREATE INDEX idx_files_folder ON files (folder)",
      "CREATE INDEX idx_files_deleted_at ON files (deleted_at)",
      "CREATE INDEX idx_files_created ON files (created)",
    ],
  });

  app.save(files);
}, (app) => {
  // Rollback drops the records but never the blobs — those live outside
  // pb_data and nothing in this project is wired to remove them.
  const files = app.findCollectionByNameOrId("files");
  app.delete(files);
});
