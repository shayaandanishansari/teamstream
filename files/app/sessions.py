"""The cookie session, and why it is a server-side map.

THE PROBLEM THIS SOLVES: `<img src>` and `<video src>` cannot send an
Authorization header. There is no attribute for it, no way to intercept it
without a service worker, and no amount of care in the client changes that. Any
design where file bytes need a bearer token means every thumbnail in the grid is
a broken image.

The existing `attachments` collection dodges this by serving file bytes
UNAUTHENTICATED and relying on unguessable URLs — a trade-off its migration
comment states plainly. We can do better here only because we are writing the
service ourselves: a cookie rides along on subresource requests automatically.

WHY AN OPAQUE TOKEN AGAINST A MAP, rather than the two obvious alternatives:

  A signed cookie (itsdangerous) needs a secret that survives restart — which is
  the same durability problem, plus a secret file to manage — and signed cookies
  CANNOT BE REVOKED. Signing out on a lost phone would do nothing until expiry.

  A purely in-memory map is revocable and needs no secret, but dies on restart.
  With `Restart=always` in the unit file, one OOM would sign all three people
  out mid-video for no reason they could see.

So: a server-side map, persisted atomically to sessions.json. Three users and a
few devices is a dozen rows. Revocable, restart-surviving, and no cryptography
to get subtly wrong.

WHAT IS STORED IS sha256(sid), NOT the sid. So sessions.json is not a file full
of live bearer tokens — someone who reads it cannot use what they find.
"""

from __future__ import annotations

import hashlib
import secrets
import time
from dataclasses import dataclass
from typing import Any

from . import atomic
from .config import settings

COOKIE = "ts_files"


def _hash(sid: str) -> str:
    return hashlib.sha256(sid.encode("utf-8")).hexdigest()


@dataclass
class Session:
    member_id: str
    member_name: str
    created: float
    expires: float


class SessionStore:
    def __init__(self) -> None:
        self._rows: dict[str, Session] = {}
        self._dirty = False
        self._load()

    def _load(self) -> None:
        raw = atomic.read_json(settings.sessions_file) or {}
        now = time.time()
        for sid_hash, row in raw.items():
            try:
                s = Session(**row)
            except TypeError:
                continue
            if s.expires > now:
                self._rows[sid_hash] = s

    def save(self) -> None:
        if not self._dirty:
            return
        atomic.write_json(
            settings.sessions_file,
            {k: v.__dict__ for k, v in self._rows.items()},
        )
        self._dirty = False

    def mint(self, member_id: str, member_name: str) -> tuple[str, Session]:
        """A new session. Signing in on a second device leaves the first alone —
        logging in on the phone must not sign out the laptop."""
        sid = secrets.token_urlsafe(32)
        now = time.time()
        s = Session(
            member_id=member_id,
            member_name=member_name,
            created=now,
            expires=now + settings.session_days * 86400,
        )
        self._rows[_hash(sid)] = s
        self._dirty = True
        self.save()
        return sid, s

    def get(self, sid: str | None) -> Session | None:
        if not sid:
            return None
        s = self._rows.get(_hash(sid))
        if s is None:
            return None
        if s.expires <= time.time():
            self.revoke(sid)
            return None
        return s

    def touch(self, sid: str, s: Session) -> bool:
        """Slide the expiry when it is within five days of running out.

        Returns whether the caller should re-send Set-Cookie. Sliding rather
        than fixed, so somebody who uses the app weekly is never logged out, and
        somebody who stops using it is.
        """
        remaining = s.expires - time.time()
        if remaining > (settings.session_days - 5) * 86400:
            return False
        s.expires = time.time() + settings.session_days * 86400
        self._dirty = True
        self.save()
        return True

    def revoke(self, sid: str) -> None:
        if self._rows.pop(_hash(sid), None) is not None:
            self._dirty = True
            self.save()

    def sweep(self) -> int:
        now = time.time()
        gone = [k for k, v in self._rows.items() if v.expires <= now]
        for k in gone:
            del self._rows[k]
        if gone:
            self._dirty = True
            self.save()
        return len(gone)

    def count(self) -> int:
        return len(self._rows)

    def cookie_kwargs(self) -> dict[str, Any]:
        return {
            "key": COOKIE,
            "httponly": True,
            "secure": settings.cookie_secure,
            # Lax, not Strict. Strict drops the cookie on a top-level navigation
            # from another app — so a file link shared in WhatsApp would 401 —
            # and the <img>/<video> subresources this exists for are same-origin
            # anyway, where Lax applies regardless.
            "samesite": "lax",
            # Scoped to /files, so it never rides along on PocketBase's /api
            # requests. Nothing gains from it being sent there.
            "path": "/files",
            "max_age": settings.session_days * 86400,
        }


store = SessionStore()
