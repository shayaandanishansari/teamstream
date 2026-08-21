"""The TeamStream file service.

PocketBase owns records and identity. This owns bytes. A file has a row in
PocketBase and a blob under /srv/teamstream-files, and neither service
duplicates the other's job.

It exists because PocketBase cannot do large uploads: its file field is one
multipart request, with no chunking and no resume, and Cloudflare's free plan
refuses a request body over 100MB at the edge before the box ever sees it. No
backend setting raises that ceiling — only chunking does.

Everything is mounted under /files, which is the path cloudflared routes here.
Note that this owns the /files/* URL namespace outright, which is why the web
app's own file page lives at /drive.
"""

from __future__ import annotations

import asyncio
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI

from . import errors, pb, sessions
from .config import ensure_dirs, log_capabilities, settings
from .routes import files, health, session, uploads

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
log = logging.getLogger("teamstream.files")


async def _sweeper() -> None:
    """Housekeeping, every thirty minutes.

    It removes exactly one class of thing: abandoned uploads under tmp/, whose
    bytes are genuinely disposable because nobody has a file yet.

    It does NOT remove blobs. A blob directory with no `.complete`, or one with
    no database record, is REPORTED through /files/health and left alone. The
    never-destroy rule covers the ambiguous cases especially — recovering one by
    hand takes a minute because meta.json holds the real name, the uploader and
    the folder, and recovering a deleted one takes a backup.
    """
    while True:
        try:
            for upload_id in uploads.store.expired_uploads():
                uploads.store.discard(upload_id)
                log.info("swept abandoned upload %s", upload_id)
            gone = sessions.store.sweep()
            if gone:
                log.info("expired %d session(s)", gone)
            orphans = uploads.store.orphans()
            if orphans:
                log.warning(
                    "%d blob(s) need a human: %s",
                    len(orphans),
                    ", ".join(f"{o['file_id']} ({o['why']})" for o in orphans[:5]),
                )
        except Exception:  # noqa: BLE001 - the loop must outlive one bad pass
            log.exception("sweeper pass failed")
        await asyncio.sleep(30 * 60)


@asynccontextmanager
async def lifespan(_: FastAPI):
    ensure_dirs()
    log_capabilities()
    log.info("store at %s, PocketBase at %s", settings.root, settings.pb_url)
    task = asyncio.create_task(_sweeper())
    try:
        yield
    finally:
        task.cancel()
        await pb.aclose()
        sessions.store.save()


app = FastAPI(
    title="TeamStream files",
    version="1.0.0",
    lifespan=lifespan,
    # No docs in production: they are a map of the service for anyone who finds
    # the path, and the three people using this have the source.
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
)

errors.install(app)

app.include_router(health.router, prefix="/files")
app.include_router(session.router, prefix="/files")
app.include_router(uploads.router, prefix="/files")
# LAST. Its routes are /{file_id}, which would otherwise swallow /health,
# /session and /uploads as if they were file ids.
app.include_router(files.router, prefix="/files")
