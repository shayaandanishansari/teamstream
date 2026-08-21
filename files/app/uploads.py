"""The chunked, resumable upload state machine. No HTTP in this module.

THREE INVARIANTS, in priority order. Everything else follows from them.

  1. THE FILE LENGTH IS THE STATE. `received` is always
     `os.stat(data.part).st_size` — never a counter in JSON that can disagree
     with the disk after a crash, a torn write or a killed process.

  2. APPEND-ONLY, NEVER SEEK. The part file is opened in "ab", which on POSIX
     makes it physically impossible for a seek to affect where bytes land. A
     chunk that arrives at the wrong offset is REFUSED, not helpfully placed.

  3. A 200 MEANS DURABLE. flush + fsync happen before the response, not after.
     A client that got a 200 for a chunk may delete its copy of those bytes.

The payoff for (1) is that a torn chunk costs nothing: the connection drops
mid-write, some bytes landed, `received` reports exactly how many, and the
client re-slices from there. There is no repair path because there is no state
to repair.
"""

from __future__ import annotations

import asyncio
import hashlib
import logging
import os
import shutil
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

from . import atomic, paths
from .config import Settings

log = logging.getLogger("teamstream.files")

STATE = "state.json"
PART = "data.part"
META = "meta.json"

# Served inline only if the sniffed type is on this list.
#
# THIS IS A SECURITY BOUNDARY, not a convenience. Blobs are served from the SAME
# ORIGIN as the app — that is the whole point of routing /files/* by path rather
# than putting the service on its own hostname. So an uploaded .html or .svg
# opened inline runs as our origin and can read the PocketBase token straight out
# of localStorage. Everything not on this list is sent as an attachment with
# application/octet-stream, whatever the client claimed it was.
#
# Note SVG is deliberately absent: it is an image to a person and a script host
# to a browser.
INLINE_TYPES = {"application/pdf", "text/plain"}
INLINE_PREFIXES = ("image/", "video/", "audio/")


def _inline_safe(mime: str) -> bool:
    if mime == "image/svg+xml":
        return False
    return mime in INLINE_TYPES or mime.startswith(INLINE_PREFIXES)


# Magic bytes for the handful of types where the extension is worth
# double-checking. Not a full libmagic: this is a shared drive for three people,
# and the job is to stop a .html being served inline, not to classify every file
# format in existence.
_MAGIC: tuple[tuple[bytes, int, str], ...] = (
    (b"\xff\xd8\xff", 0, "image/jpeg"),
    (b"\x89PNG\r\n\x1a\n", 0, "image/png"),
    (b"GIF87a", 0, "image/gif"),
    (b"GIF89a", 0, "image/gif"),
    (b"%PDF-", 0, "application/pdf"),
    (b"WEBP", 8, "image/webp"),
    (b"ftypheic", 4, "image/heic"),
    (b"ftypheix", 4, "image/heic"),
    (b"ftypmif1", 4, "image/heif"),
    (b"ftypqt  ", 4, "video/quicktime"),
    (b"ftypisom", 4, "video/mp4"),
    (b"ftypmp42", 4, "video/mp4"),
    (b"\x1aE\xdf\xa3", 0, "video/x-matroska"),
    (b"PK\x03\x04", 0, "application/zip"),
)


def sniff_mime(head: bytes, name: str, declared: str) -> str:
    """Decide the type from the BYTES, falling back to the extension.

    The client's declared type is recorded but never trusted — it is the one
    input an attacker fully controls, and it decides whether we serve inline.
    """
    for magic, offset, mime in _MAGIC:
        if head[offset : offset + len(magic)] == magic:
            # A zip that calls itself something more specific (docx, xlsx) is
            # still not inline-safe, so the generic answer costs nothing.
            return mime

    import mimetypes

    guessed, _ = mimetypes.guess_type(name)
    if guessed:
        # An extension-only guess must never unlock inline rendering: renaming
        # evil.html to evil.png is exactly the move this defends against.
        return guessed if not _inline_safe(guessed) else "application/octet-stream"
    return declared or "application/octet-stream"


@dataclass
class UploadState:
    upload_id: str
    file_id: str
    name: str
    size: int
    declared_mime: str
    folder: str
    task: str | None
    fingerprint: str
    member_id: str
    member_name: str
    created_at: str
    expires_at: float
    client_sha256: str | None = None
    #: Set once finish has succeeded, so a repeated call is answerable.
    finished: bool = False

    def to_json(self) -> dict[str, Any]:
        return self.__dict__.copy()

    @staticmethod
    def from_json(d: dict[str, Any]) -> "UploadState":
        # Tolerate keys an older or newer version wrote, rather than throwing
        # away a live upload because a field was added.
        known = UploadState.__dataclass_fields__
        return UploadState(**{k: v for k, v in d.items() if k in known})


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


class UploadStore:
    def __init__(self, settings: Settings) -> None:
        self.s = settings
        # One lock per upload, so two chunks for the same upload cannot
        # interleave inside this process. `_locks` is guarded because
        # setdefault on a plain dict is not atomic across an await.
        self._locks: dict[str, asyncio.Lock] = {}
        self._guard = asyncio.Lock()

    async def lock_for(self, upload_id: str) -> asyncio.Lock:
        async with self._guard:
            return self._locks.setdefault(upload_id, asyncio.Lock())

    def _dir(self, upload_id: str) -> Path:
        return paths.upload_dir(self.s.root, upload_id)

    # -- create ------------------------------------------------------------

    def find_resumable(self, fingerprint: str, member_id: str) -> UploadState | None:
        """An unexpired upload of the same file by the same person.

        This is what makes `POST /uploads` idempotent, and it is the entire
        resume story for a browser: a `File` handle from a drop cannot be re-read
        after a reload, so "resume" honestly means *the user re-drops the same
        file and zero bytes are re-sent*. Keying on
        sha256(name|size|lastModified|folder) needs no client-side storage at
        all — which is why it works on the phone that just crashed.
        """
        if not self.s.tmp.is_dir():
            return None
        for d in self.s.tmp.iterdir():
            state = atomic.read_json(d / STATE)
            if not state:
                continue
            try:
                st = UploadState.from_json(state)
            except TypeError:
                continue
            if (
                st.fingerprint == fingerprint
                and st.member_id == member_id
                and st.expires_at > time.time()
                and (d / PART).exists()
            ):
                return st
        return None

    def create(self, state: UploadState) -> UploadState:
        d = self._dir(state.upload_id)
        d.mkdir(parents=True, exist_ok=True)
        (d / PART).touch()
        atomic.write_json(d / STATE, state.to_json())
        atomic.fsync_dir(d)
        return state

    # -- read --------------------------------------------------------------

    def state(self, upload_id: str) -> UploadState:
        d = self._dir(upload_id)
        raw = atomic.read_json(d / STATE)
        if raw is None:
            raise FileNotFoundError("no such upload")
        return UploadState.from_json(raw)

    def received(self, upload_id: str) -> int:
        """Invariant 1. The only source of truth for how much has arrived."""
        part = self._dir(upload_id) / PART
        try:
            return part.stat().st_size
        except OSError:
            raise FileNotFoundError("no such upload") from None

    # -- append ------------------------------------------------------------

    def open_part(self, upload_id: str):
        return open(self._dir(upload_id) / PART, "ab")

    # -- finish ------------------------------------------------------------

    def hash_and_head(self, upload_id: str) -> tuple[str, bytes]:
        """Stream-hash the part, and grab its first 4KB for sniffing.

        Blocking and CPU-bound — roughly two seconds per 2GB — so callers run it
        in a thread. It doubles as an integrity read-back: the bytes are read
        off the disk they were written to, not out of a buffer.
        """
        part = self._dir(upload_id) / PART
        h = hashlib.sha256()
        head = b""
        with open(part, "rb") as f:
            while True:
                block = f.read(1024 * 1024)
                if not block:
                    break
                if not head:
                    head = block[:4096]
                h.update(block)
        return h.hexdigest(), head

    def finalise(self, st: UploadState, sha256: str, mime: str) -> dict[str, Any]:
        """Move the bytes into place and write the sidecar.

        The order is chosen so that every crash window is recoverable, and the
        `.complete` sentinel is what makes the difference visible afterwards:

          rename -> meta.json -> fsync -> .complete

        Crash before `.complete` and the blob directory is reported as an orphan
        and NEVER deleted. Crash after it but before the PocketBase record and
        the next `finish` call heals it, because the bytes are already durable
        and finish is idempotent.
        """
        udir = self._dir(st.upload_id)
        part = udir / PART
        atomic.fsync_file(part)
        atomic.fsync_dir(udir)

        bdir = paths.blob_dir(self.s.root, st.file_id)
        bdir.mkdir(parents=True, exist_ok=True)

        stored = paths.safe_name(st.name)
        dest = bdir / stored
        if not dest.exists():
            # Same filesystem, so this is atomic: the file is either absent or
            # complete, never half-written.
            atomic.retry_move(lambda: os.replace(part, dest))

        meta = {
            "meta_version": 1,
            "file_id": st.file_id,
            "name": st.name,
            "stored_name": stored,
            "size": dest.stat().st_size,
            "sha256": sha256,
            "mime": mime,
            "declared_mime": st.declared_mime,
            "inline_safe": _inline_safe(mime),
            "folder": st.folder,
            "task": st.task,
            "uploaded_by": {"id": st.member_id, "name": st.member_name},
            "created_at": st.created_at,
            "completed_at": _now_iso(),
            "upload_id": st.upload_id,
            "pb_record_id": None,
            "pb_collection": "files",
            "deleted_at": None,
        }
        atomic.write_json(bdir / META, meta)
        atomic.fsync_dir(bdir)
        atomic.mark_complete(bdir, sha256)
        return meta

    def record_pb_id(self, file_id: str, record_id: str) -> None:
        """Second write to meta.json, once PocketBase has the row.

        Its ABSENCE is the orphan signal the sweeper reports on — a blob that is
        complete on disk but has no record anywhere.
        """
        bdir = paths.blob_dir(self.s.root, file_id)
        meta = atomic.read_json(bdir / META)
        if meta is None:
            return
        meta["pb_record_id"] = record_id
        atomic.write_json(bdir / META, meta)

    def meta(self, file_id: str) -> dict[str, Any]:
        bdir = paths.blob_dir(self.s.root, file_id)
        meta = atomic.read_json(bdir / META)
        if meta is None:
            raise FileNotFoundError("no such file")
        return meta

    def discard(self, upload_id: str) -> None:
        """Abandon an upload. Only ever removes things under tmp/."""
        shutil.rmtree(self._dir(upload_id), ignore_errors=True)

    def settle(self, upload_id: str) -> None:
        """A finished upload: drop the bytes, KEEP the receipt.

        Deleting the whole directory here was the obvious move and it was wrong.
        It made `finish` answer 404 on a second call, so a client whose success
        response was lost in flight — the exact case the 409-with-received
        design protects against everywhere else — could not tell "it worked" from
        "it is gone". Keeping state.json costs a few hundred bytes for 24 hours
        and makes finish genuinely idempotent.

        `data.part` goes immediately, because that is the multi-gigabyte half,
        and `find_resumable` requires a part file, so this upload can never be
        resumed into afterwards. The sweeper reaps the rest at the usual TTL.
        """
        d = self._dir(upload_id)
        (d / PART).unlink(missing_ok=True)
        raw = atomic.read_json(d / STATE) or {}
        raw["finished"] = True
        atomic.write_json(d / STATE, raw)

    # -- housekeeping ------------------------------------------------------

    def expired_uploads(self) -> Iterable[str]:
        if not self.s.tmp.is_dir():
            return []
        out = []
        cutoff = time.time()
        for d in self.s.tmp.iterdir():
            raw = atomic.read_json(d / STATE)
            if raw is None:
                # No state at all: judge it by the part file's age rather than
                # deleting something we cannot identify.
                try:
                    if time.time() - d.stat().st_mtime > self.s.upload_ttl_hours * 3600:
                        out.append(d.name)
                except OSError:
                    pass
                continue
            if float(raw.get("expires_at", 0)) < cutoff:
                out.append(d.name)
        return out

    def orphans(self) -> list[dict[str, Any]]:
        """Blob directories that are not finished, or have no record.

        REPORTED, NEVER DELETED. The never-destroy rule covers everything under
        blobs/, including the ambiguous — especially the ambiguous. Recovering
        one by hand is a minute's work because meta.json holds the real name,
        the uploader and the folder; recovering a deleted one is impossible.
        """
        found: list[dict[str, Any]] = []
        if not self.s.blobs.is_dir():
            return found
        for d in self.s.blobs.iterdir():
            if not d.is_dir():
                continue
            meta = atomic.read_json(d / META)
            if not atomic.is_complete(d):
                found.append({"file_id": d.name, "why": "incomplete"})
            elif meta is not None and not meta.get("pb_record_id"):
                found.append({"file_id": d.name, "why": "no database record"})
        return found
