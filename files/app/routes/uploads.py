"""The upload endpoints. All the durability reasoning lives in ../uploads.py."""

from __future__ import annotations

import asyncio
import logging
import shutil
import time
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field
from starlette.requests import ClientDisconnect

from .. import atomic, paths, pb
from ..auth import Caller, require_write
from ..config import settings
from ..errors import ApiError
from ..uploads import UploadState, UploadStore, sniff_mime

log = logging.getLogger("teamstream.files")
router = APIRouter()
store = UploadStore(settings)


class CreateUpload(BaseModel):
    name: str
    size: int = Field(ge=0)
    mime: str = ""
    folder: str = ""
    task: str | None = None
    #: sha256(name|size|lastModified|folder), computed by the client. Makes
    #: create idempotent, which is the entire resume story — see
    #: UploadStore.find_resumable.
    fingerprint: str
    sha256: str | None = None


def _iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


@router.post("/uploads")
async def create(body: CreateUpload, who: Caller = Depends(require_write)) -> JSONResponse:
    name = paths.safe_name(body.name)
    if not name:
        raise ApiError(400, "that file has no usable name")

    resumed = store.find_resumable(body.fingerprint, who.member_id)
    if resumed is not None:
        return JSONResponse(
            {
                "upload_id": resumed.upload_id,
                "file_id": resumed.file_id,
                "chunk_size": settings.chunk_size,
                "received": store.received(resumed.upload_id),
                "expires_at": resumed.expires_at,
                "resumed": True,
            },
            status_code=200,
        )

    # Refuse early rather than halfway through a 4GB transfer. 10% headroom
    # because the store is not the only thing on that disk.
    try:
        free = shutil.disk_usage(settings.root).free
        if body.size and free < body.size * 1.1:
            raise ApiError(507, "not enough free disk for that file")
    except OSError:
        pass

    state = UploadState(
        upload_id=paths.mint_id(),
        # Minted HERE, at create — not at finish. That is what makes finish
        # idempotent, gives the client a stable id to show immediately, and lets
        # a crash between the rename and the record be healed rather than
        # guessed at.
        file_id=paths.mint_id(),
        name=name,
        size=body.size,
        declared_mime=body.mime or "",
        folder=(body.folder or "").strip()[:120],
        task=body.task,
        fingerprint=body.fingerprint,
        member_id=who.member_id,
        member_name=who.member_name,
        created_at=_iso(),
        expires_at=time.time() + settings.upload_ttl_hours * 3600,
        client_sha256=body.sha256,
    )
    store.create(state)
    return JSONResponse(
        {
            "upload_id": state.upload_id,
            "file_id": state.file_id,
            "chunk_size": settings.chunk_size,
            "received": 0,
            "expires_at": state.expires_at,
            "resumed": False,
        },
        status_code=201,
    )


@router.get("/uploads/{upload_id}")
async def status(upload_id: str, who: Caller = Depends(require_write)) -> dict:
    st = store.state(paths.valid_id(upload_id))
    if st.member_id != who.member_id:
        raise ApiError(404, "no such upload")
    return {
        "upload_id": st.upload_id,
        "file_id": st.file_id,
        "name": st.name,
        "size": st.size,
        "received": store.received(upload_id),
        "chunk_size": settings.chunk_size,
        "expires_at": st.expires_at,
    }


@router.put("/uploads/{upload_id}")
async def append(request: Request, upload_id: str, offset: int, who: Caller = Depends(require_write)) -> dict:
    """Append one chunk.

    The offset is in the QUERY STRING rather than a header on purpose: it
    survives being copy-pasted out of the browser's network tab, which is how
    this will actually be debugged at 1am.
    """
    upload_id = paths.valid_id(upload_id)
    st = store.state(upload_id)
    if st.member_id != who.member_id:
        raise ApiError(404, "no such upload")

    lock = await store.lock_for(upload_id)
    async with lock:
        received = store.received(upload_id)
        if offset != received:
            # ALWAYS a 409 with the truth, never a "helpful" partial accept.
            # The client re-slices from `received`; nothing can be lost or
            # doubled because `received` is the file's own length. This also
            # covers the case where our 200 was lost on the way back.
            raise ApiError(409, "offset mismatch", received=received)
        if st.size and offset > st.size:
            raise ApiError(413, "past the declared size")

        written = 0
        with store.open_part(upload_id) as fh:
            buf = bytearray()
            try:
                async for block in request.stream():
                    buf.extend(block)
                    # Hand off in 1MB pieces: peak memory is ~1MB per upload
                    # regardless of how big the chunk is, and the event loop is
                    # free between hops. The body is never fully buffered.
                    while len(buf) >= 1024 * 1024:
                        piece = bytes(buf[: 1024 * 1024])
                        del buf[: 1024 * 1024]
                        if st.size and received + written + len(piece) > st.size:
                            raise ApiError(413, "past the declared size")
                        await asyncio.to_thread(fh.write, piece)
                        written += len(piece)
                if buf:
                    piece = bytes(buf)
                    if st.size and received + written + len(piece) > st.size:
                        raise ApiError(413, "past the declared size")
                    await asyncio.to_thread(fh.write, piece)
                    written += len(piece)
            except ClientDisconnect:
                # NOT an error. The bytes that landed are durable and counted;
                # the client's next status call gets the true number and
                # continues from there. This is the whole payoff of "the file
                # length is the state".
                log.info("client vanished mid-chunk on %s at +%d", upload_id, written)
            finally:
                fh.flush()
                import os as _os

                _os.fsync(fh.fileno())

    return {"received": store.received(upload_id)}


@router.post("/uploads/{upload_id}/finish")
async def finish(upload_id: str, who: Caller = Depends(require_write)) -> dict:
    """Seal the upload. Idempotent: calling it twice returns the same body.

    Idempotence is not a nicety here — it is the crash-recovery mechanism. If
    the process died after the bytes were in place but before PocketBase had the
    row, calling finish again heals it.
    """
    upload_id = paths.valid_id(upload_id)
    st = store.state(upload_id)
    if st.member_id != who.member_id:
        raise ApiError(404, "no such upload")
    if who.token is None:
        raise ApiError(401, "not signed in")

    lock = await store.lock_for(upload_id)
    async with lock:
        bdir = paths.blob_dir(settings.root, st.file_id)

        if atomic.is_complete(bdir):
            meta = store.meta(st.file_id)
            record_id = meta.get("pb_record_id")
            if not record_id:
                # The crash-heal path, and also the "PocketBase was down for a
                # second" path.
                record_id = await pb.create_file_record(
                    who.token, who.member_id, who.member_name, meta
                )
                store.record_pb_id(st.file_id, record_id)
            store.settle(upload_id)
            return _finished(meta, record_id)

        received = store.received(upload_id)
        if st.size and received != st.size:
            raise ApiError(409, "incomplete", received=received, size=st.size)

        sha256, head = await asyncio.to_thread(store.hash_and_head, upload_id)
        if st.client_sha256 and st.client_sha256.lower() != sha256:
            # Keep the part for its 24h rather than deleting the evidence.
            raise ApiError(422, "checksum mismatch")

        mime = sniff_mime(head, st.name, st.declared_mime)
        meta = await asyncio.to_thread(store.finalise, st, sha256, mime)

        record_id = await pb.create_file_record(
            who.token, who.member_id, who.member_name, meta
        )
        store.record_pb_id(st.file_id, record_id)
        store.settle(upload_id)
        return _finished(meta, record_id)


def _finished(meta: dict, record_id: str) -> dict:
    return {
        "file_id": meta["file_id"],
        "record_id": record_id,
        "name": meta["name"],
        "size": meta["size"],
        "sha256": meta["sha256"],
        "mime": meta["mime"],
        "inline_safe": meta["inline_safe"],
        "folder": meta.get("folder", ""),
        "created": meta["completed_at"],
    }


@router.delete("/uploads/{upload_id}", status_code=204)
async def abandon(upload_id: str, who: Caller = Depends(require_write)) -> None:
    upload_id = paths.valid_id(upload_id)
    try:
        st = store.state(upload_id)
    except FileNotFoundError:
        return
    if st.member_id != who.member_id:
        raise ApiError(404, "no such upload")
    # Only ever removes something under tmp/. Nothing in this service deletes
    # anything under blobs/.
    store.discard(upload_id)
