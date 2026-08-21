import type { RecordModel } from "pocketbase";
import { readDate, readNum, readStr } from "./wire";

/* Port of app/lib/models/attachment.dart.
 *
 * Attachments are the EXISTING per-task feature: a screenshot pinned to a task,
 * stored in PocketBase's own file field, capped at 20MB, cascade-deleted with
 * the task. They are deliberately NOT the same thing as the shared drive in
 * models/fileRec.ts — see that file's header.
 *
 * The size/extension helpers below are kept because the file explorer reuses
 * them (plan.md §5); they are pure string arithmetic and belong to neither
 * store in particular. */

export interface Attachment {
  id: string;
  taskId: string;   // wire: "task"
  memberId: string; // wire: "member"
  /** The ORIGINAL filename. PocketBase randomises the name it stores, so this
   *  field is the only place the real one survives. */
  name: string;
  url: string;
  thumbUrl: string;
  size: number;
  created: Date;
  /** Client-only: a placeholder that has not reached the server yet. */
  uploading: boolean;
  /** Client-only: bytes held for an instant preview of an image mid-upload. */
  localPreview: string | null;
}

/* Built by hand rather than through `pb.files.getURL`, so the model layer stays
 * a pure function of the record and needs no client instance. This is the same
 * URL the SDK constructs.
 *
 * `thumbs` must list every size the app can ask for: PocketBase serves the
 * FULL-SIZE original for any thumb spec not declared in the migration, which on
 * a board full of phone photos is megabytes per tile. 240x240 is the only size
 * 1721700300_add_attachments.js declares. */
const fileUrl = (r: RecordModel, stored: string, thumb?: string): string => {
  if (!stored) return "";
  const base = `/api/files/${r.collectionId}/${r.id}/${encodeURIComponent(stored)}`;
  return thumb ? `${base}?thumb=${thumb}` : base;
};

export const toAttachment = (r: RecordModel): Attachment => {
  const stored = readStr(r.file);
  return {
    id: r.id,
    taskId: readStr(r.task),
    memberId: readStr(r.member),
    name: readStr(r.name),
    url: fileUrl(r, stored),
    thumbUrl: fileUrl(r, stored, "240x240"),
    size: readNum(r.size),
    created: readDate(r.created) ?? new Date(),
    uploading: false,
    localPreview: null,
  };
};

/* ---- shared filename helpers ------------------------------------------- */

const IMAGE_EXTENSIONS = new Set([
  "png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "heif", "avif",
]);

/** Lowercase, no dot, `''` when there is no extension or the dot is last. */
export function extensionOf(name: string): string {
  const i = name.lastIndexOf(".");
  if (i < 0 || i === name.length - 1) return "";
  return name.slice(i + 1).toLowerCase();
}

export const isImageName = (name: string): boolean =>
  IMAGE_EXTENSIONS.has(extensionOf(name));

/** "" / "812 B" / "43 KB" / "1.4 MB" — ported from Dart's prettySize. */
export function prettySize(bytes: number): string {
  if (bytes <= 0) return "";
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`;
  const mb = bytes / (1024 * 1024);
  if (mb < 1024) return `${mb.toFixed(1)} MB`;
  return `${(mb / 1024).toFixed(1)} GB`;
}
