"""Serving bytes and thumbnails.

Note what is NOT here: there is no listing endpoint, deliberately. The file list
is `GET /api/collections/files/records` against PocketBase, which owns records
and gives realtime for free. "PocketBase owns records, FastAPI owns bytes" is
only a real boundary if it is mechanical — adding a convenient `/files/list`
here is the obvious wrong move, and it would immediately become a second source
of truth about what exists.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, Query, Request
from fastapi.responses import FileResponse, JSONResponse, Response

from .. import paths, pb, sessions, thumbs
from ..auth import Caller, require_read, require_write
from ..config import settings
from ..errors import ApiError
from ..uploads import UploadStore

router = APIRouter()
store = UploadStore(settings)

# A year, and honest — unlike the reference's hour, which was not.
#
# video_editor caches `/api/thumb?path=<path>` for an hour. A path can be
# rewritten underneath you, so a re-encoded video kept serving its old poster
# for up to an hour even though the disk cache had correctly regenerated. Ours
# is keyed by `file_id`, which is minted once and never reused — "same name
# uploaded twice = a new record" guarantees a new blob gets a new id, so a URL's
# content genuinely cannot change. `immutable` is a fact here, not a hope.
#
# `private` rather than `public`: the response sits behind a cookie and
# Cloudflare's edge has no business holding it.
IMMUTABLE = "private, max-age=31536000, immutable"


def _maybe_refresh_cookie(request: Request, response: Response) -> None:
    if getattr(request.state, "refresh_cookie", False):
        sid = request.cookies.get(sessions.COOKIE)
        s = sessions.store.get(sid)
        if sid and s:
            response.set_cookie(value=sid, **sessions.store.cookie_kwargs())


@router.get("/{file_id}")
async def download(
    request: Request,
    file_id: str,
    download: int = Query(0),
    who: Caller = Depends(require_read),
) -> Response:
    meta = store.meta(paths.valid_id(file_id))
    bdir = paths.blob_dir(settings.root, file_id)
    blob = paths.stored_blob(bdir)
    if blob is None:
        raise ApiError(404, "no such file")

    inline = bool(meta.get("inline_safe")) and not download
    resp = FileResponse(
        blob,
        # Explicit, because FileResponse defaults to text/plain when its own
        # guess fails — and an unknown type that renders as text is exactly the
        # thing the inline allowlist exists to prevent.
        media_type=meta["mime"] if inline else "application/octet-stream",
        filename=meta["name"],
        content_disposition_type="inline" if inline else "attachment",
        headers={
            "Cache-Control": IMMUTABLE,
            # Belt to the allowlist's braces: even for an inline type, the
            # browser must not sniff its way to something executable.
            "X-Content-Type-Options": "nosniff",
        },
    )
    _maybe_refresh_cookie(request, resp)
    return resp


@router.get("/{file_id}/thumb")
async def thumb(
    request: Request,
    file_id: str,
    w: int = Query(480),
    who: Caller = Depends(require_read),
) -> Response:
    meta = store.meta(paths.valid_id(file_id))
    if w not in thumbs.WIDTHS:
        raise ApiError(400, f"width must be one of {', '.join(map(str, thumbs.WIDTHS))}")

    path = await thumbs.ensure(file_id, meta["mime"], w)
    if path is None:
        # A SHORT cache on the miss, not a year.
        #
        # "No thumbnail" can stop being true: install ffmpeg on the box and
        # every video should start showing a poster. Caching that 404 for a year
        # would mean the fix never reaches anyone's browser. An hour is long
        # enough to stop a grid of PDFs hammering the endpoint and short enough
        # that the box healing heals the client too.
        return JSONResponse(
            {"error": "no thumbnail for this file"},
            status_code=404,
            headers={"Cache-Control": "public, max-age=3600"},
        )

    resp = FileResponse(path, media_type="image/jpeg", headers={"Cache-Control": IMMUTABLE})
    _maybe_refresh_cookie(request, resp)
    return resp


@router.get("/{file_id}/meta")
async def meta(file_id: str, who: Caller = Depends(require_read)) -> dict:
    m = dict(store.meta(paths.valid_id(file_id)))
    bdir = paths.blob_dir(settings.root, file_id)
    from .. import atomic

    m["on_disk"] = {
        "complete": atomic.is_complete(bdir),
        "present": paths.stored_blob(bdir) is not None,
        "thumb_possible": thumbs.available_for(m.get("mime", "")),
    }
    return m


@router.post("/{file_id}/delete")
async def soft_delete(file_id: str, who: Caller = Depends(require_write)) -> dict:
    """A POST, not a DELETE — the verb should not lie about what happens.

    This sets `deleted_at` on the PocketBase row. THE BLOB IS NOT TOUCHED, and
    there is no code path anywhere in this service that removes anything under
    blobs/. Reaping is a manual chore, run deliberately, never wired into the
    app.
    """
    m = store.meta(paths.valid_id(file_id))
    record_id = m.get("pb_record_id")
    if not record_id:
        raise ApiError(409, "this file has no database record yet")
    assert who.token
    await pb.soft_delete(who.token, who.member_id, who.member_name, record_id)
    return {"file_id": file_id, "deleted": True}


@router.post("/{file_id}/restore")
async def restore(file_id: str, who: Caller = Depends(require_write)) -> dict:
    m = store.meta(paths.valid_id(file_id))
    record_id = m.get("pb_record_id")
    if not record_id:
        raise ApiError(409, "this file has no database record yet")
    assert who.token
    await pb.soft_delete(who.token, who.member_id, who.member_name, record_id, restore=True)
    return {"file_id": file_id, "deleted": False}
