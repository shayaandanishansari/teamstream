import type { RecordModel } from "pocketbase";
import { readDate, readNum, readRel, readStr } from "./wire";

/* The shared drive — the `files` collection added by 1721700400_add_files.js.
 *
 * Deliberately a SEPARATE collection from `attachments`, and the difference is
 * not cosmetic:
 *
 *   attachments  a screenshot pinned to a task. Bytes live in PocketBase's file
 *                field, 20MB cap, cascadeDelete: true — deleting the task takes
 *                the screenshot with it, which is correct.
 *   files        a shared drive. Bytes live under /srv/teamstream-files/ behind
 *                the FastAPI service, no size cap, cascadeDelete: FALSE, and
 *                deleteRule: null so nothing can hard-delete a row through the
 *                API at all. "Delete" sets deleted_at; the blob stays forever.
 *
 * A cascade here would be fatal: cascades run BELOW the API rules, so deleting
 * a member would destroy exactly the rows deleteRule exists to protect.
 *
 * There is no `file` field. PocketBase owns the record; FastAPI owns the bytes.
 */
export interface FileRec {
  id: string;
  /** The join key to the blob on disk. Minted by FastAPI at upload-create, 26
   *  lowercase base32 chars, never reused — which is what makes the download
   *  and thumbnail URLs safe to cache as `immutable`. */
  fileId: string; // wire: "file_id"
  name: string;
  /** One flat string, not a tree. A folder plus a filter chip is 95% of the
   *  value; nesting means rename/move/orphan handling. */
  folder: string;
  size: number;
  /** Sniffed server-side. Never the client's declared type. */
  mime: string;
  sha256: string;
  memberId: string;      // wire: "member" — who uploaded it
  taskId: string | null; // wire: "task", optional
  deletedAt: Date | null;   // wire: "deleted_at"
  deletedById: string | null; // wire: "deleted_by"
  created: Date;
}

export const toFileRec = (r: RecordModel): FileRec => ({
  id: r.id,
  fileId: readStr(r.file_id),
  name: readStr(r.name),
  folder: readStr(r.folder),
  size: readNum(r.size),
  mime: readStr(r.mime),
  sha256: readStr(r.sha256),
  memberId: readStr(r.member),
  taskId: readRel(r.task),
  deletedAt: readDate(r.deleted_at),
  deletedById: readRel(r.deleted_by),
  created: readDate(r.created) ?? new Date(),
});

export const blobUrl = (f: FileRec): string => `/files/${f.fileId}`;
export const downloadUrl = (f: FileRec): string => `/files/${f.fileId}?download=1`;
export const thumbUrl = (f: FileRec, w: 240 | 480 | 960 = 480): string =>
  `/files/${f.fileId}/thumb?w=${w}`;

/** Whether a thumbnail is worth ASKING for. Deliberately a pure function of the
 *  mime type and NOT a stored flag: a `has_thumb` boolean computed when ffmpeg
 *  was missing would say false forever after ffmpeg is installed. A 404 is the
 *  fallback, and it heals itself. */
export function couldHaveThumb(mime: string): boolean {
  return (
    mime.startsWith("image/") ||
    mime.startsWith("video/") ||
    mime === "application/pdf"
  );
}
