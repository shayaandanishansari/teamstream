import { useEffect, useMemo, useRef, useState } from "react";
import { useStore } from "../data/store";
import { filesApi, uploadFile, type Progress } from "../data/filesApi";
import {
  couldHaveThumb,
  downloadUrl,
  blobUrl,
  thumbUrl,
  type FileRec,
} from "../models/fileRec";
import { extensionOf, prettySize } from "../models/attachment";
import { Shot } from "./Shot";
import { useDepartures } from "./useDepartures";
import "./drive.css";

/* The shared drive.
 *
 * The grid, the card, the empty states and the failed-thumbnail behaviour come
 * from video_editor's Library.js / Folder.js / bits.js. The drag-and-drop, the
 * chunk loop and the progress reporting are new — that codebase has no upload
 * path at all, because files arrive in it by being dropped into a folder in
 * Explorer.
 *
 * Two things it does NOT do, both deliberate:
 *
 *   No folder TREE. A `folder` string plus a filter chip is 95% of the value;
 *   nesting means rename, move and orphan handling, which is the layer this
 *   project exists to avoid.
 *
 *   No listing call to the file service. The list is PocketBase's `files`
 *   collection, already in the store and already realtime, so a file somebody
 *   else uploads appears here without a refresh. FastAPI owns bytes and nothing
 *   else.
 */

type Upload = {
  key: string;
  name: string;
  size: number;
  progress: Progress | null;
  error: string | null;
  done: boolean;
};

const fileKey = (f: FileRec) => f.id;

function when(d: Date): string {
  const days = Math.floor((Date.now() - d.getTime()) / 86_400_000);
  if (days === 0) return "today";
  if (days === 1) return "yesterday";
  if (days < 7) return d.toLocaleDateString(undefined, { weekday: "long" });
  return d.toLocaleDateString(undefined, { day: "numeric", month: "short" });
}

function FileCard({
  file,
  who,
  leaving,
  onDelete,
  onRestore,
}: {
  file: FileRec;
  who: string;
  leaving: boolean;
  onDelete: () => void;
  onRestore: () => void;
}) {
  const deleted = file.deletedAt !== null;
  const ext = extensionOf(file.name).toUpperCase();

  return (
    <li className={"card row-anim" + (leaving ? " is-leaving" : "") + (deleted ? " is-deleted" : "")}>
      <a
        className="card-shot"
        href={blobUrl(file)}
        target="_blank"
        rel="noreferrer"
        aria-label={`Open ${file.name}`}
      >
        <Shot
          src={couldHaveThumb(file.mime) ? thumbUrl(file, 480) : null}
          fallback={ext || "FILE"}
        />
      </a>

      <div className="card-body">
        <p className="card-name" title={file.name}>{file.name}</p>
        <p className="card-meta">
          {/* "uploaded by Umair" means "whoever was signed in as Umair" — with
              one shared password the drive should not imply more certainty
              than the login provides. */}
          {who} · {when(file.created)}
          {file.folder && <> · {file.folder}</>}
        </p>
        <p className="card-tags">
          {ext && <span className="tag">{ext}</span>}
          <span className="tag">{prettySize(file.size)}</span>
          {deleted && <span className="tag tag-deleted">deleted</span>}
        </p>
      </div>

      <div className="card-actions">
        <a className="ghost" href={downloadUrl(file)}>Download</a>
        {deleted ? (
          <button className="ghost" onClick={onRestore}>Restore</button>
        ) : (
          <button className="ghost" onClick={onDelete}>Delete</button>
        )}
      </div>
    </li>
  );
}

export function Drive() {
  const s = useStore();
  const [folder, setFolder] = useState<string | null>(null);
  const [showDeleted, setShowDeleted] = useState(false);
  const [uploads, setUploads] = useState<Upload[]>([]);
  const [dragging, setDragging] = useState(false);
  const [target, setTarget] = useState("");
  const [serviceDown, setServiceDown] = useState<string | null>(null);
  const input = useRef<HTMLInputElement>(null);
  const dragDepth = useRef(0);

  /* One cookie, once. Everything the grid renders — every thumbnail, every
   * preview — is a subresource request that cannot carry a header. */
  useEffect(() => {
    filesApi
      .openSession()
      .then(() => filesApi.health())
      .then(() => setServiceDown(null))
      .catch((e: Error) => setServiceDown(e.message));
  }, []);

  const memberName = useMemo(() => {
    const m = new Map(s.members.map((x) => [x.id, x.name]));
    return (id: string) => m.get(id) ?? "someone";
  }, [s.members]);

  const folders = useMemo(() => {
    const set = new Set<string>();
    for (const f of s.files) if (f.folder) set.add(f.folder);
    return [...set].sort();
  }, [s.files]);

  const shown = useMemo(() => {
    return s.files
      .filter((f) => (showDeleted ? true : f.deletedAt === null))
      .filter((f) => (folder === null ? true : f.folder === folder))
      .slice()
      .sort((a, b) => b.created.getTime() - a.created.getTime());
  }, [s.files, folder, showDeleted]);

  const { rendered, leaving } = useDepartures(shown, fileKey);

  async function send(list: FileList | File[]) {
    const files = [...list];
    for (const file of files) {
      const key = `${file.name}:${file.size}:${file.lastModified}`;
      setUploads((u) => [
        ...u.filter((x) => x.key !== key),
        { key, name: file.name, size: file.size, progress: null, error: null, done: false },
      ]);

      const patch = (p: Partial<Upload>) =>
        setUploads((u) => u.map((x) => (x.key === key ? { ...x, ...p } : x)));

      try {
        await uploadFile(file, {
          folder: target.trim(),
          onProgress: (progress) => patch({ progress }),
        });
        patch({ done: true });
        // The row arrives through PocketBase realtime, so nothing here needs to
        // insert it. Clear the progress line once it has had a moment to read.
        setTimeout(() => setUploads((u) => u.filter((x) => x.key !== key)), 2500);
      } catch (e) {
        patch({ error: (e as Error).message });
      }
    }
  }

  return (
    <main
      className={"drive" + (dragging ? " is-dragging" : "")}
      onDragEnter={(e) => {
        e.preventDefault();
        dragDepth.current += 1;
        setDragging(true);
      }}
      onDragOver={(e) => e.preventDefault()}
      onDragLeave={(e) => {
        e.preventDefault();
        /* Depth-counted, not a bare boolean: dragging over a child fires
         * dragleave on the parent, so a naive flag flickers off every time the
         * pointer crosses a card. */
        dragDepth.current -= 1;
        if (dragDepth.current <= 0) {
          dragDepth.current = 0;
          setDragging(false);
        }
      }}
      onDrop={(e) => {
        e.preventDefault();
        dragDepth.current = 0;
        setDragging(false);
        if (e.dataTransfer.files.length) void send(e.dataTransfer.files);
      }}
    >
      <header className="drive-head">
        <div>
          <p className="label">Drive</p>
          <h1>Everything we&rsquo;ve put somewhere safe</h1>
        </div>
        <div className="drive-actions">
          <input
            className="folder-input"
            placeholder="Folder (optional)"
            value={target}
            onChange={(e) => setTarget(e.target.value)}
            aria-label="Folder for new uploads"
          />
          <button onClick={() => input.current?.click()}>Add files</button>
          <input
            ref={input}
            type="file"
            multiple
            hidden
            onChange={(e) => {
              if (e.target.files?.length) void send(e.target.files);
              e.target.value = "";
            }}
          />
        </div>
      </header>

      {serviceDown && (
        <p className="banner banner-fatal" role="alert">
          The file service isn&rsquo;t answering ({serviceDown}). Uploads and
          previews won&rsquo;t work until it&rsquo;s back — the list below is
          from the database and is still accurate.
        </p>
      )}

      {(folders.length > 0 || showDeleted) && (
        <div className="chips">
          <button className={folder === null ? "on" : ""} onClick={() => setFolder(null)}>
            All
          </button>
          {folders.map((f) => (
            <button key={f} className={folder === f ? "on" : ""} onClick={() => setFolder(f)}>
              {f}
            </button>
          ))}
          <button
            className={"chip-toggle" + (showDeleted ? " on" : "")}
            onClick={() => setShowDeleted(!showDeleted)}
          >
            {showDeleted ? "Hiding nothing" : "Show deleted"}
          </button>
        </div>
      )}

      {uploads.length > 0 && (
        <ul className="uploads">
          {uploads.map((u) => (
            <li key={u.key}>
              <span className="up-name">{u.name}</span>
              {u.error ? (
                <span className="up-error">{u.error}</span>
              ) : u.done ? (
                <span className="up-done">done</span>
              ) : u.progress ? (
                <>
                  <span className="up-bar">
                    <span
                      style={{ inlineSize: `${(u.progress.sent / Math.max(1, u.progress.total)) * 100}%` }}
                    />
                  </span>
                  {/* The multi-GB case: a percentage alone stops meaning
                      anything, and "chunk 3 of 47" says what is actually
                      happening. */}
                  <span className="tnum up-count">
                    {u.progress.chunks > 1
                      ? `chunk ${u.progress.chunk} of ${u.progress.chunks}`
                      : prettySize(u.progress.sent)}
                    {u.progress.resumed && " · resumed"}
                  </span>
                </>
              ) : (
                <span className="up-count">starting…</span>
              )}
            </li>
          ))}
        </ul>
      )}

      {rendered.length === 0 ? (
        <p className="drive-empty">
          Nothing here yet. Drop files anywhere on this page, or use Add files.
        </p>
      ) : (
        <ul className="grid">
          {rendered.map((f) => (
            <FileCard
              key={f.id}
              file={f}
              who={memberName(f.memberId)}
              leaving={leaving.has(f.id)}
              onDelete={() => void filesApi.softDelete(f.fileId)}
              onRestore={() => void filesApi.restore(f.fileId)}
            />
          ))}
        </ul>
      )}

      {dragging && <div className="drop-veil">Drop to upload</div>}
    </main>
  );
}
