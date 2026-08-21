"""Liveness, and an honest answer about what this box can do.

No auth: it is a probe, and it deliberately leaks nothing — capability booleans,
free space, and counts. Knowing that ffmpeg is installed tells an attacker
nothing they could not learn by uploading a video.
"""

from __future__ import annotations

import os
import shutil

from fastapi import APIRouter

from ..config import capabilities, settings
from ..routes.uploads import store
from .. import sessions

router = APIRouter()


@router.get("/health")
async def health() -> dict:
    try:
        usage = shutil.disk_usage(settings.root)
        free_bytes = usage.free
    except OSError:
        free_bytes = None

    free_inodes = None
    if hasattr(os, "statvfs"):
        try:
            # Inodes matter here and are easy to forget: every upload makes a
            # directory plus two or three files, so a store can run out of
            # inodes with plenty of bytes left.
            free_inodes = os.statvfs(settings.root).f_favail
        except OSError:
            pass

    orphans = store.orphans()
    return {
        "ok": True,
        "capabilities": capabilities(),
        "disk": {"free_bytes": free_bytes, "free_inodes": free_inodes},
        # Reported, never reaped. A number here that is not zero is a job for a
        # person, not for the service.
        "orphans": len(orphans),
        "orphan_ids": [o["file_id"] for o in orphans[:20]],
        "sessions": sessions.store.count(),
    }
