"""Settings and the boot-time capability probe.

Everything configurable arrives as an environment variable set by the systemd
unit (deploy/teamstream-files.service) or by run.bat in development. There is no
config file: two deployments, five settings, and a file would be a third place
for them to disagree.
"""

from __future__ import annotations

import logging
import os
import shutil
from dataclasses import dataclass
from pathlib import Path

log = logging.getLogger("teamstream.files")


def _bool(name: str, default: bool) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


@dataclass(frozen=True)
class Settings:
    root: Path
    pb_url: str
    cookie_secure: bool
    session_days: int = 30
    # 8MB. Cloudflare's free plan refuses a request body over 100MB at the edge,
    # before the box ever sees it, and no backend setting raises that — so the
    # chunk size is not a tuning knob, it is the thing that makes multi-GB
    # uploads possible at all. 8 leaves a wide margin for headers and for
    # Cloudflare counting differently than we do.
    chunk_size: int = 8 * 1024 * 1024
    # An abandoned upload's bytes are disposable: nobody has a file yet.
    upload_ttl_hours: int = 24

    @property
    def blobs(self) -> Path:
        return self.root / "blobs"

    @property
    def thumbs(self) -> Path:
        return self.root / "thumbs"

    @property
    def tmp(self) -> Path:
        return self.root / "tmp"

    @property
    def sessions_file(self) -> Path:
        return self.root / "sessions.json"


def load() -> Settings:
    return Settings(
        root=Path(os.getenv("TS_FILES_ROOT", "/srv/teamstream-files")).resolve(),
        pb_url=os.getenv("TS_PB_URL", "http://127.0.0.1:8090").rstrip("/"),
        # A flag rather than a fact to remember. Chrome and Firefox do accept
        # Secure cookies over http://127.0.0.1 because localhost is a secure
        # context, so dev works either way — but being explicit means nobody has
        # to know that.
        cookie_secure=_bool("TS_COOKIE_SECURE", True),
    )


settings = load()

# ---------------------------------------------------------------------------
# Capabilities, probed once at boot.
#
# The rule for every one of these: MISSING MEANS DEGRADE, NEVER FAIL. A box
# without ffmpeg should serve every image and PDF perfectly and simply not offer
# video posters. Only Pillow is required, because without it there is no
# thumbnail pipeline at all.

HAS_FFMPEG = shutil.which("ffmpeg") is not None

try:
    import pypdfium2  # noqa: F401

    HAS_PDF = True
except Exception:  # pragma: no cover - depends on the box
    HAS_PDF = False

try:
    import pillow_heif

    pillow_heif.register_heif_opener()
    HAS_HEIF = True
except Exception:  # pragma: no cover - depends on the box
    HAS_HEIF = False


def capabilities() -> dict[str, bool]:
    return {"ffmpeg": HAS_FFMPEG, "pdf": HAS_PDF, "heif": HAS_HEIF}


def log_capabilities() -> None:
    """One line naming what is missing and what it costs.

    Deliberately one line and not a warning per request: a box without ffmpeg is
    a supported configuration, not an error state, and logging it per thumbnail
    would bury everything else.
    """
    missing = [name for name, ok in capabilities().items() if not ok]
    if not missing:
        log.info("thumbnails: images, video and PDF all available")
        return
    costs = {
        "ffmpeg": "no video posters",
        "pdf": "no PDF first pages",
        "heif": "no iPhone .heic photos",
    }
    log.warning(
        "thumbnails degraded - missing %s (%s). Everything else still works; "
        "install the tool and it heals within the hour.",
        ", ".join(missing),
        "; ".join(costs[m] for m in missing),
    )


def ensure_dirs() -> None:
    for d in (settings.blobs, settings.thumbs, settings.tmp):
        d.mkdir(parents=True, exist_ok=True)
