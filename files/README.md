# TeamStream file service

FastAPI + uvicorn on `127.0.0.1:8091`, behind the Cloudflare tunnel at
`/files/*`. It owns **bytes**. PocketBase owns **records and identity**. A file
has a row in `files` and a blob under `/srv/teamstream-files`, and neither
service does the other's job.

There is deliberately **no listing endpoint**. The file list is
`GET /api/collections/files/records` against PocketBase, which already has
realtime. Adding a convenient `/files/list` here is the obvious wrong move — it
would immediately become a second source of truth about what exists.

## Why this exists at all

PocketBase's file field is one multipart request: no chunking, no resume. And
the 100MB ceiling is **Cloudflare's**, enforced at the edge before the box sees
the request, so no backend setting raises it. Chunked upload against a
filesystem is about a hundred lines and gives resume for free, which multi-GB
over a home uplink needs anyway.

## Sacred and disposable

The taxonomy is lifted from `video_editor`'s CLAUDE.md, and it is here rather
than only in DEPLOY.md so the next person reads it next to the thing it
describes — otherwise somebody backs up forty gigabytes of regenerable JPEGs.

| Path | Policy | Why |
|---|---|---|
| `blobs/` | **SACRED.** Back up weekly, keep forever. | The files themselves. Nothing in this service deletes anything here — there is no code path that does, including in the sweeper. |
| `blobs/<id>/meta.json` | **SACRED.** | Deliberate redundancy: name, size, sha256, uploader, folder, timestamps. Lose `data.db` entirely and the store is still fully recoverable, because every blob sits under its REAL name with a sidecar saying whose it is. That property is the whole point of this project. |
| `blobs/<id>/.complete` | **SACRED.** | Written last. Its presence is the only thing distinguishing a finished upload from one that died mid-rename; a size check cannot tell them apart. |
| `thumbs/` | **Disposable — exclude from backups.** | Pure cache, versioned in the filename, regenerates on demand. |
| `tmp/` | **Disposable — exclude.** | In-flight uploads only. Swept after 24h. |
| `sessions.json` | **Exclude.** | Restoring it would resurrect revoked sessions. |

`/srv/teamstream-files/` lives **outside `pb_data/`** on purpose: DEPLOY.md says
to back up all of `pb_data/`, and if blobs lived there every database backup
would become a multi-gigabyte copy.

## The three upload invariants

1. **The file length is the state.** `received` is always
   `os.stat(data.part).st_size` — never a counter in JSON that can disagree with
   the disk after a crash. This is why a torn chunk costs nothing and why there
   is no repair path: there is no state to repair.
2. **Append-only, never seek.** The part file is opened `"ab"`. A chunk at the
   wrong offset gets a `409` carrying the true `received`; the client re-slices.
   Never a "helpful" partial accept.
3. **A 200 means durable.** `flush` + `fsync` happen before the response.

`finish` is idempotent, and that is a mechanism rather than a nicety: it is how
a crash between "bytes in place" and "row in the database" gets healed.

## Degrading

Only Pillow is required. Missing `ffmpeg` means no video posters; missing
`pypdfium2` means no PDF first pages; missing `pillow-heif` means no iPhone
`.heic` photos. In every case **the service still runs and everything else still
works**, one line is logged at boot naming what is missing, and the thumbnail
endpoint 404s with a *short* `max-age` so installing the tool later heals within
the hour.

There is deliberately no stored `has_thumb` flag: computed while ffmpeg was
missing, it would read `false` forever afterwards.

## Running it

```bash
python -m venv .venv && .venv/bin/pip install -r requirements.txt
TS_FILES_ROOT=/srv/teamstream-files \
TS_PB_URL=http://127.0.0.1:8090 \
TS_COOKIE_SECURE=1 \
  .venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8091
```

On Windows, `run.bat` at the repo root starts this alongside PocketBase and Vite.

## Checking it

```bash
python -m pytest tests/test_range.py     # Range/206, offline
python tests/verify_service.py           # end to end, needs the service + PocketBase running
curl -s localhost:8091/files/health      # capabilities, free disk, orphan count
```

`test_range.py` asserts one behaviour per bug found in the reference
implementation this service replaced, so a Starlette upgrade that regresses
Range fails the suite rather than the team's video player.

`orphans` in `/files/health` being non-zero is a job for a person, not for the
service: a blob with no `.complete`, or one with no database record, is
**reported and never touched**. `meta.json` holds everything needed to
reconstruct the row by hand.

## Security notes worth not undoing

- **Blobs are served from the same origin as the app.** An uploaded `.html` or
  `.svg` rendered inline would run as our origin and could read the PocketBase
  token out of localStorage. `INLINE_TYPES` in `app/uploads.py` is an allowlist,
  the mime is **sniffed from the bytes** rather than taken from the client, and
  everything else is `application/octet-stream` + `Content-Disposition:
  attachment` + `nosniff`.
- **GETs accept a cookie; writes require the header.** That kills CSRF, and it
  falls out of the design anyway — `finish` needs a forwardable PocketBase token
  because the record is created *as the caller*.
- **No superuser credential exists anywhere in this service.** See `app/pb.py`.
