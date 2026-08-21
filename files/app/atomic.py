"""Durable writes: temp file, fsync, rename.

All of this is lifted from video_editor, where each piece exists because
something actually broke:

  - the per-writer temp name, from `context.write_json`: a shared `.tmp` was
    fine while one thread wrote at a time, and two writers both replacing it
    hit each other's open handle on Windows with "Access is denied".
  - `retry_move`, from `library._retry_move`: a file that was just written is
    routinely still open a moment later because the indexer or the virus
    scanner got to it first. This killed a preview mid-build on that project's
    first real run.
  - `.complete` sentinels, from its CLAUDE.md: "written last and is what says
    the extraction finished; a count cannot tell a full set from a run that was
    killed at 40%."

The Windows-specific ones only matter on the dev machine — the box is Linux —
but they cost about eight lines each and the failures they prevent are the kind
that look like corruption.
"""

from __future__ import annotations

import json
import os
import threading
import time
from pathlib import Path
from typing import Any, Callable, TypeVar

T = TypeVar("T")


def retry_move(fn: Callable[[], T], attempts: int = 6, delay: float = 0.15) -> T:
    """Run a rename/replace, riding out a handle another process is holding."""
    for i in range(attempts):
        try:
            return fn()
        except PermissionError:
            if i == attempts - 1:
                raise
            time.sleep(delay * (i + 1))
    raise AssertionError("unreachable")


def fsync_file(path: Path) -> None:
    """Flush a file that is already closed.

    Opened O_RDWR rather than O_RDONLY: on Windows, fsync of a read-only handle
    fails with EBADF, because flushing is a write operation there. Linux is
    happy either way, so the portable spelling costs nothing.
    """
    fd = os.open(path, os.O_RDWR)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def fsync_dir(path: Path) -> None:
    """Persist the DIRECTORY ENTRY, not just the file's contents.

    Without this a rename can still be lost on power failure even though the
    bytes were fsynced: the file exists on disk but nothing points at it. Not
    available on Windows, where opening a directory fails — harmless, because
    the only place durability across power loss matters is the box.
    """
    try:
        fd = os.open(path, os.O_RDONLY)
    except (OSError, PermissionError):
        return
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


def _temp_beside(path: Path, suffix: str = ".tmp") -> Path:
    """A temp name unique to THIS writer.

    pid and thread id, so two processes or two threads writing the same target
    cannot collide on the temp file and then race each other's replace.
    """
    return path.with_suffix(f"{path.suffix}.{os.getpid()}.{threading.get_ident()}{suffix}")


def _write_and_sync(path: Path, data: bytes) -> None:
    """Write and flush through the SAME handle.

    Reopening the file just to fsync it is one syscall's worth of tidiness and
    two ways to be wrong: the handle may be denied (Windows read-only fsync) and
    the file may have moved underneath. Flush what we are holding.
    """
    with open(path, "wb") as fh:
        fh.write(data)
        fh.flush()
        os.fsync(fh.fileno())


def write_json(path: Path, data: Any) -> None:
    """Write JSON so a reader never sees a half-written file."""
    tmp = _temp_beside(path)
    try:
        _write_and_sync(tmp, json.dumps(data, indent=2, ensure_ascii=False).encode("utf-8"))
        retry_move(lambda: tmp.replace(path))
        fsync_dir(path.parent)
    finally:
        if tmp.exists():
            tmp.unlink(missing_ok=True)


def read_json(path: Path) -> Any | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        # A missing file and an unreadable one are the same answer to the only
        # question callers ask: is there a usable record here?
        return None


def write_bytes_atomic(path: Path, data: bytes) -> None:
    tmp = _temp_beside(path)
    try:
        _write_and_sync(tmp, data)
        retry_move(lambda: tmp.replace(path))
        fsync_dir(path.parent)
    finally:
        if tmp.exists():
            tmp.unlink(missing_ok=True)


COMPLETE = ".complete"


def mark_complete(dir_: Path, note: str = "") -> None:
    """Say that this directory is whole.

    Written LAST, after the bytes and the sidecar are both on disk and synced.
    Its presence is the only thing that distinguishes a finished upload from one
    that died between the rename and the record — a size check cannot, because a
    part file that happens to be the right length looks identical.
    """
    write_bytes_atomic(dir_ / COMPLETE, note.encode("utf-8"))


def is_complete(dir_: Path) -> bool:
    return (dir_ / COMPLETE).exists()
