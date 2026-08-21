"""Mint, read and revoke the cookie session. See ../sessions.py for why."""

from __future__ import annotations

from fastapi import APIRouter, Depends, Request, Response

from .. import sessions
from ..auth import Caller, require_read, require_write

router = APIRouter()


@router.post("/session", status_code=204)
async def create(response: Response, who: Caller = Depends(require_write)) -> None:
    """Exchange a PocketBase token for a cookie.

    Called once after login. The cookie is what makes <img src> and <video src>
    work at all — neither can send an Authorization header.
    """
    sid, _ = sessions.store.mint(who.member_id, who.member_name)
    response.set_cookie(value=sid, **sessions.store.cookie_kwargs())


@router.get("/session")
async def read(request: Request, who: Caller = Depends(require_read)) -> dict:
    sid = request.cookies.get(sessions.COOKIE)
    s = sessions.store.get(sid)
    return {
        "member_id": who.member_id,
        "member_name": who.member_name,
        "expires": s.expires if s else None,
        "via": "cookie" if who.token is None else "header",
    }


@router.delete("/session", status_code=204)
async def destroy(request: Request, response: Response) -> None:
    """Revocable, which is the whole reason sessions are a server-side map
    rather than a signed cookie."""
    sid = request.cookies.get(sessions.COOKIE)
    if sid:
        sessions.store.revoke(sid)
    kwargs = sessions.store.cookie_kwargs()
    kwargs["max_age"] = 0
    response.set_cookie(value="", **kwargs)
