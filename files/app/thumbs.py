"""Thumbnails: mime dispatch, cached, never blocking a listing.

The mechanics are `library.poster()` from video_editor, widened from video to
everything and hardened in three places where that version would not survive
being served over a network:

  WIDTHS ARE AN ALLOWLIST, not a clamp. The reference clamps to 160..1920, which
  lets one client mint 1,761 distinct jpgs of a single file — a disk-fill
  primitive even with three users, and a guaranteed cold cache the day somebody
  retunes a CSS width.

  THE VERSION IS IN THE FILENAME (`v1_480.jpg`), not stamped inside the file.
  `probe_cached`'s lesson is that a record written before a field existed is
  worse than no record; putting the version in the NAME means bumping it is a
  cold cache with zero staleness logic to get wrong.

  GENERATION IS BOUNDED. Scrolling fifty tiles into view in a request-per-thread
  server is fifty concurrent ffmpegs fighting over one disk. A semaphore of two,
  and a timeout, means a big folder is slow rather than fatal.

MISSING TOOLS DEGRADE. No ffmpeg means videos have no poster and everything else
still works — and the 404 carries a SHORT max-age, so installing ffmpeg later
heals within the hour instead of being cached away for a year.
"""

from __future__ import annotations

import asyncio
import logging
import os
import threading
from pathlib import Path

from . import atomic, paths
from .config import HAS_FFMPEG, HAS_PDF, settings

log = logging.getLogger("teamstream.files")

WIDTHS = (240, 480, 960)
VERSION = "v1"

# Two at a time, whatever asks. Pillow and pypdfium2 are blocking C calls that
# go to a thread; ffmpeg is a subprocess that needs no thread at all.
_gate = asyncio.Semaphore(2)

_locks: dict[str, asyncio.Lock] = {}
_locks_guard = asyncio.Lock()


async def _lock_for(key: str) -> asyncio.Lock:
    async with _locks_guard:
        return _locks.setdefault(key, asyncio.Lock())


def kind_of(mime: str) -> str | None:
    if mime.startswith("image/"):
        return "image"
    if mime.startswith("video/"):
        return "video"
    if mime == "application/pdf":
        return "pdf"
    return None


def available_for(mime: str) -> bool:
    kind = kind_of(mime)
    if kind is None:
        return False
    if kind == "video":
        return HAS_FFMPEG
    if kind == "pdf":
        return HAS_PDF
    return True


def _dest(file_id: str, width: int) -> Path:
    return paths.thumb_dir(settings.root, file_id) / f"{VERSION}_{width}.jpg"


def _negative(file_id: str, width: int) -> Path:
    return paths.thumb_dir(settings.root, file_id) / f"{VERSION}_{width}.none"


def _render_image(src: Path, dest_tmp: Path, width: int) -> None:
    from PIL import Image, ImageFile, ImageOps

    # A phone photo that was cut off mid-transfer should still make a tile
    # rather than take the row out.
    ImageFile.LOAD_TRUNCATED_IMAGES = True
    with Image.open(src) as im:
        # Without this, every portrait photo from a phone comes out sideways:
        # the pixels are landscape and an EXIF tag says "rotate me".
        im = ImageOps.exif_transpose(im)
        im = im.convert("RGB")
        im.thumbnail((width, width * 4), Image.LANCZOS)
        im.save(dest_tmp, "JPEG", quality=82, optimize=True)


def _render_pdf(src: Path, dest_tmp: Path, width: int) -> None:
    import pypdfium2 as pdfium

    doc = pdfium.PdfDocument(src)
    try:
        page = doc[0]
        scale = max(0.2, min(4.0, width / max(1.0, page.get_width())))
        pil = page.render(scale=scale).to_pil().convert("RGB")
        pil.thumbnail((width, width * 4))
        pil.save(dest_tmp, "JPEG", quality=82, optimize=True)
    finally:
        doc.close()


async def _render_video(src: Path, dest_tmp: Path, width: int) -> bool:
    """A frame a tenth of the way in, falling back to the very first frame.

    `-ss` goes BEFORE `-i` deliberately: that is a keyframe seek, which is
    nearly free, where `-ss` after the input decodes everything up to that point.
    A tenth of the way in is far enough past a black frame or a hand over the
    lens to be recognisable.
    """
    for seek in ("2", "0"):
        proc = await asyncio.create_subprocess_exec(
            "ffmpeg", "-nostdin", "-loglevel", "error",
            "-ss", seek, "-i", str(src),
            "-frames:v", "1",
            # -2 keeps the aspect ratio and forces an even height, which the
            # encoder requires.
            "-vf", f"scale={width}:-2",
            "-q:v", "4", "-y", str(dest_tmp),
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
        )
        try:
            await asyncio.wait_for(proc.wait(), timeout=20)
        except asyncio.TimeoutError:
            proc.kill()
            await proc.wait()
            continue
        if dest_tmp.exists() and dest_tmp.stat().st_size > 0:
            return True
    return False


async def ensure(file_id: str, mime: str, width: int) -> Path | None:
    """Return a cached thumbnail path, generating it if needed.

    None means "there is no thumbnail for this", which the route turns into a
    404 the UI answers with an extension chip.
    """
    if width not in WIDTHS:
        raise ValueError("unsupported width")
    if not available_for(mime):
        return None

    dest = _dest(file_id, width)
    # Fast path, no lock: an existing file is an existing file.
    if dest.exists():
        return dest
    if _negative(file_id, width).exists():
        return None

    lock = await _lock_for(f"{file_id}:{width}")
    async with lock:
        # The double check that stops forty-seven tiles scrolling into view from
        # forking forty-seven ffmpegs for the same file.
        if dest.exists():
            return dest
        if _negative(file_id, width).exists():
            return None

        bdir = paths.blob_dir(settings.root, file_id)
        src = paths.stored_blob(bdir)
        if src is None:
            return None

        dest.parent.mkdir(parents=True, exist_ok=True)
        # Per-writer temp name: a shared .part means two writers both replace it
        # and the second hits the first's open handle.
        tmp = dest.with_suffix(f".{os.getpid()}.{threading.get_ident()}.part.jpg")

        try:
            async with _gate:
                kind = kind_of(mime)
                if kind == "video":
                    ok = await _render_video(src, tmp, width)
                else:
                    fn = _render_image if kind == "image" else _render_pdf
                    await asyncio.to_thread(fn, src, tmp, width)
                    ok = tmp.exists() and tmp.stat().st_size > 0

            if not ok:
                raise RuntimeError("no frame produced")

            atomic.retry_move(lambda: tmp.replace(dest))
            return dest
        except Exception as exc:  # noqa: BLE001 - any failure is "no thumbnail"
            log.info("no thumbnail for %s (%s): %s", file_id, mime, exc)
            # Stamp the failure, so one unthumbnailable file in a folder of
            # fifty is not retried on every single listing. Straight from
            # probe_cached's "failures are stamped too".
            try:
                _negative(file_id, width).touch()
            except OSError:
                pass
            return None
        finally:
            if tmp.exists():
                tmp.unlink(missing_ok=True)
