import { pb } from "./pb";

/* The client half of the file service.
 *
 * `api.js` from video_editor ports as-is for the shape — unwrap errors once,
 * not at twenty call sites — because the service was built to answer with one
 * error shape (`{"error": "..."}`) precisely so this could stay small.
 *
 * The upload loop is NEW. video_editor has no upload code at all: files arrive
 * there by being dropped into a folder in Explorer, and the server only ever
 * discovers them. There was nothing to lift.
 */

export interface FileService {
  ok: boolean;
  capabilities: { ffmpeg: boolean; pdf: boolean; heif: boolean };
  disk: { free_bytes: number | null; free_inodes: number | null };
  orphans: number;
  sessions: number;
}

async function unwrap<T>(r: Response): Promise<T> {
  let body: unknown = null;
  try {
    body = await r.json();
  } catch {
    /* empty, or not json */
  }
  if (!r.ok) {
    const message =
      (body as { error?: string } | null)?.error || r.statusText || "request failed";
    const err = new Error(message) as Error & { status: number; body: unknown };
    err.status = r.status;
    err.body = body;
    throw err;
  }
  return body as T;
}

const authHeaders = (): Record<string, string> => ({
  Authorization: pb.authStore.token,
});

export const filesApi = {
  health: () => fetch("/files/health").then((r) => unwrap<FileService>(r)),

  /** Exchange the PocketBase token for a cookie.
   *
   * Called once after sign-in, and again if a GET ever 401s. The cookie is the
   * only reason `<img src>` and `<video src>` work: neither can carry an
   * Authorization header, and there is no way to make them. */
  openSession: () =>
    fetch("/files/session", { method: "POST", headers: authHeaders() }).then((r) => {
      if (!r.ok && r.status !== 204) return unwrap(r);
      return null;
    }),

  closeSession: () => fetch("/files/session", { method: "DELETE" }),

  softDelete: (fileId: string) =>
    fetch(`/files/${fileId}/delete`, { method: "POST", headers: authHeaders() }).then(
      (r) => unwrap<{ file_id: string; deleted: boolean }>(r),
    ),

  restore: (fileId: string) =>
    fetch(`/files/${fileId}/restore`, { method: "POST", headers: authHeaders() }).then(
      (r) => unwrap<{ file_id: string; deleted: boolean }>(r),
    ),
};

/** sha256(name|size|lastModified|folder), hex.
 *
 * The server keys resumability on this, so re-dropping the same file after a
 * reload continues where it stopped with zero bytes re-sent — and it needs no
 * client-side storage at all, which is what makes it work on the phone that
 * just crashed. */
export async function fingerprint(file: File, folder: string): Promise<string> {
  const material = `${file.name}|${file.size}|${file.lastModified}|${folder}`;
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(material));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export interface Progress {
  sent: number;
  total: number;
  chunk: number;
  chunks: number;
  resumed: boolean;
}

export interface Finished {
  file_id: string;
  record_id: string;
  name: string;
  size: number;
  sha256: string;
  mime: string;
  inline_safe: boolean;
  folder: string;
  created: string;
}

export class UploadCancelled extends Error {}

/**
 * Upload one file, in chunks, resumably.
 *
 * The loop is deliberately dull, because everything clever lives on the server:
 * ask where to start, send from there, and if the server disagrees about the
 * offset, believe the server. It answers a wrong offset with 409 and the true
 * `received`, so the only correct response is to re-slice — never to retry the
 * same bytes, and never to seek.
 */
export async function uploadFile(
  file: File,
  opts: {
    folder?: string;
    taskId?: string | null;
    onProgress?: (p: Progress) => void;
    signal?: AbortSignal;
  } = {},
): Promise<Finished> {
  const folder = opts.folder ?? "";
  const fp = await fingerprint(file, folder);

  const created = await fetch("/files/uploads", {
    method: "POST",
    headers: { ...authHeaders(), "Content-Type": "application/json" },
    body: JSON.stringify({
      name: file.name,
      size: file.size,
      mime: file.type || "application/octet-stream",
      folder,
      task: opts.taskId ?? null,
      fingerprint: fp,
    }),
    signal: opts.signal,
  }).then((r) =>
    unwrap<{
      upload_id: string;
      file_id: string;
      chunk_size: number;
      received: number;
      resumed: boolean;
    }>(r),
  );

  const { upload_id: id, chunk_size: chunkSize } = created;
  let sent = created.received;
  const chunks = Math.max(1, Math.ceil(file.size / chunkSize));

  const report = () =>
    opts.onProgress?.({
      sent,
      total: file.size,
      chunk: Math.min(chunks, Math.floor(sent / chunkSize) + 1),
      chunks,
      resumed: created.resumed,
    });

  report();

  while (sent < file.size) {
    if (opts.signal?.aborted) throw new UploadCancelled("upload cancelled");

    const slice = file.slice(sent, Math.min(sent + chunkSize, file.size));
    const res = await fetch(`/files/uploads/${id}?offset=${sent}`, {
      method: "PUT",
      headers: { ...authHeaders(), "Content-Type": "application/octet-stream" },
      body: slice,
      signal: opts.signal,
    });

    if (res.status === 409) {
      /* The server and we disagree about how much has arrived, and the server
       * is right — `received` is the part file's own length, so it cannot be
       * wrong. Re-slice from there. This is also the path a lost 200 takes:
       * our bytes landed, the response evaporated, and the next attempt is
       * simply told where it really is. */
      const body = (await res.json()) as { received: number };
      sent = body.received;
      report();
      continue;
    }

    const body = await unwrap<{ received: number }>(res);
    sent = body.received;
    report();
  }

  const finished = await fetch(`/files/uploads/${id}/finish`, {
    method: "POST",
    headers: authHeaders(),
    signal: opts.signal,
  });

  if (finished.status === 401) {
    /* The token expired during a long upload. The bytes are already durable
     * behind the server's `.complete` sentinel and finish is idempotent, so
     * refreshing and asking again is safe rather than a retry that might
     * duplicate something. */
    await pb.collection("members").authRefresh();
    return unwrap<Finished>(
      await fetch(`/files/uploads/${id}/finish`, {
        method: "POST",
        headers: authHeaders(),
      }),
    );
  }

  return unwrap<Finished>(finished);
}

export async function abandonUpload(uploadId: string): Promise<void> {
  await fetch(`/files/uploads/${uploadId}`, { method: "DELETE", headers: authHeaders() });
}
