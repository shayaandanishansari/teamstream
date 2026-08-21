"""Who is asking, and what that lets them do.

THE RULE, and it falls out of the design rather than being bolted on:

    GET  accepts a cookie OR a header.
    POST / PUT / DELETE require the HEADER.

Two payoffs from one line. It kills CSRF outright — a cross-site form post
carries the cookie but cannot set an Authorization header — on top of
SameSite=Lax already blocking it. And `finish` NEEDS a forwardable PocketBase
token anyway (see pb.py: the record is created as the caller), so writes could
not have used the cookie even if we wanted them to.
"""

from __future__ import annotations

import hashlib
import time
from dataclasses import dataclass

from fastapi import Request

from . import pb, sessions
from .errors import ApiError


@dataclass(frozen=True)
class Caller:
    member_id: str
    member_name: str
    #: Present only when the caller authenticated with a header. Writes need it,
    #: because the PocketBase record is created as them.
    token: str | None


# Token -> identity, for 60s.
#
# Keyed on the token's DIGEST rather than the token: a heap dump of this process
# is then not a vault of usable credentials, and the key size is bounded no
# matter how long PocketBase's tokens get.
_cache: dict[str, tuple[Caller, float]] = {}
_TTL = 60.0
# A 10s negative cache too, so a client stuck in a retry loop with a dead token
# cannot hammer PocketBase's auth endpoint on our behalf.
_negative: dict[str, float] = {}
_NEG_TTL = 10.0
_MAX = 256


def _prune() -> None:
    if len(_cache) <= _MAX:
        return
    for k, _ in sorted(_cache.items(), key=lambda kv: kv[1][1])[: len(_cache) - _MAX]:
        _cache.pop(k, None)


async def verify_token(token: str) -> Caller:
    key = hashlib.sha256(token.encode("utf-8")).hexdigest()
    now = time.monotonic()

    hit = _cache.get(key)
    if hit and hit[1] > now:
        return hit[0]
    if (until := _negative.get(key)) and until > now:
        raise ApiError(401, "not signed in")

    try:
        record = await pb.whoami(token)
    except ApiError:
        _negative[key] = now + _NEG_TTL
        raise

    caller = Caller(
        member_id=str(record["id"]),
        member_name=str(record.get("name") or ""),
        token=token,
    )
    _cache[key] = (caller, now + _TTL)
    _prune()
    return caller


def _bearer(request: Request) -> str | None:
    raw = request.headers.get("Authorization")
    if not raw:
        return None
    # PocketBase's own SDK sends the bare token; tolerate "Bearer x" too, since
    # curl users will reach for it.
    return raw[7:].strip() if raw.lower().startswith("bearer ") else raw.strip()


async def require_write(request: Request) -> Caller:
    """A caller allowed to change something. Header only."""
    token = _bearer(request)
    if not token:
        raise ApiError(401, "not signed in")
    return await verify_token(token)


async def require_read(request: Request) -> Caller:
    """A caller allowed to read bytes. Cookie or header.

    The cookie path is the whole reason this service has sessions: it is what
    lets `<img src="/files/…/thumb">` work at all.
    """
    token = _bearer(request)
    if token:
        return await verify_token(token)

    sid = request.cookies.get(sessions.COOKIE)
    s = sessions.store.get(sid)
    if s is None:
        raise ApiError(401, "not signed in")
    if sid:
        # Sliding expiry. The route re-sends Set-Cookie when this says so.
        request.state.refresh_cookie = sessions.store.touch(sid, s)
    return Caller(member_id=s.member_id, member_name=s.member_name, token=None)
