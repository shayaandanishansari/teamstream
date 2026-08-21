"""Talking to PocketBase.

The service never holds a superuser credential. Every write it makes is made
AS THE CALLER, by forwarding the member token that arrived on the request.

That is a deliberate choice with four payoffs, and the cost is stated at the
bottom because it is real:

  1. There is no superuser password in the process, the environment, the unit
     file, or any file the `teamstream` user can read. A compromised file
     service reaches the files it already serves, not the whole database.
  2. Attribution is CHECKED rather than asserted. The `files` collection has
     `createRule: "member = @request.auth.id"`, so PocketBase itself verifies
     the uploader. With a shared password, attribution is already the weakest
     link in this system — it should not also be self-declared by a service.
  3. The upload lands in the existing history stream with a real actor, because
     we forward X-Actor-Id / X-Actor-Name too. A superuser write would log with
     an empty actor forever.
  4. The failure mode is better: a token that expires during a multi-GB upload
     makes `finish` return 401, the client refreshes and calls finish again —
     which is safe, because finish is idempotent and the bytes are already
     durable behind `.complete`.

THE COST: crash recovery cannot auto-create a missing record, because there is
no token to do it with. That is why the sweeper reports orphans instead of
healing them, and why meta.json carries everything needed to recreate a row by
hand.
"""

from __future__ import annotations

import logging
from typing import Any

import httpx

from .config import settings
from .errors import ApiError

log = logging.getLogger("teamstream.files")

# One client, reused: connection pooling matters when every request to us can
# mean a request to PocketBase.
_client = httpx.AsyncClient(base_url=settings.pb_url, timeout=10.0)


async def aclose() -> None:
    await _client.aclose()


async def whoami(token: str) -> dict[str, Any]:
    """Verify a token by ASKING PocketBase, never by decoding it ourselves.

    Reimplementing a JWT check means duplicating the signing key, the algorithm,
    the expiry rules and the revocation story — four things that must then stay
    in step with a service we do not control. One HTTP call, cached for a
    minute, is cheaper in every sense.

    Note auth-refresh issues a NEW token in its response. We discard it: the
    browser's SDK manages its own.
    """
    r = await _client.post(
        "/api/collections/members/auth-refresh",
        headers={"Authorization": token},
    )
    if r.status_code != 200:
        raise ApiError(401, "not signed in")
    record = r.json().get("record") or {}
    if not record.get("id"):
        raise ApiError(401, "not signed in")
    return record


def _headers(token: str, member_id: str, member_name: str) -> dict[str, str]:
    return {
        "Authorization": token,
        # history.pb.js reads these off the request; PocketBase lowercases and
        # underscores header names, so these arrive as x_actor_id / x_actor_name.
        "X-Actor-Id": member_id,
        "X-Actor-Name": member_name,
    }


async def create_file_record(
    token: str, member_id: str, member_name: str, meta: dict[str, Any]
) -> str:
    """Create the `files` row for a finished upload. Returns the record id."""
    body = {
        "file_id": meta["file_id"],
        "name": meta["name"],
        "folder": meta.get("folder") or "",
        "size": meta["size"],
        "mime": meta["mime"],
        "sha256": meta["sha256"],
        "member": member_id,
    }
    if meta.get("task"):
        body["task"] = meta["task"]

    r = await _client.post(
        "/api/collections/files/records",
        json=body,
        headers=_headers(token, member_id, member_name),
    )
    if r.status_code in (200, 201):
        return str(r.json()["id"])

    if r.status_code == 401:
        raise ApiError(401, "your session expired — sign in and finish again")

    # The unique index on file_id is the last backstop against a racing double
    # finish. Losing that race is not an error: the row exists, which is all the
    # caller wanted. Find it and return it.
    if r.status_code == 400:
        existing = await find_by_file_id(token, meta["file_id"])
        if existing:
            return existing
    log.error("pocketbase refused the file record: %s %s", r.status_code, r.text[:400])
    raise ApiError(502, "could not record the file", file_id=meta["file_id"])


async def find_by_file_id(token: str, file_id: str) -> str | None:
    r = await _client.get(
        "/api/collections/files/records",
        params={"filter": f'file_id="{file_id}"', "perPage": 1},
        headers={"Authorization": token},
    )
    if r.status_code != 200:
        return None
    items = r.json().get("items") or []
    return str(items[0]["id"]) if items else None


async def soft_delete(
    token: str, member_id: str, member_name: str, record_id: str, restore: bool = False
) -> None:
    """Set or clear `deleted_at`. There is no hard delete anywhere in this
    service — `deleteRule: null` on the collection means PocketBase would refuse
    one even if something tried."""
    from datetime import datetime, timezone

    body: dict[str, Any] = (
        {"deleted_at": "", "deleted_by": ""}
        if restore
        else {
            "deleted_at": datetime.now(timezone.utc)
            .isoformat(timespec="milliseconds")
            .replace("+00:00", "Z"),
            "deleted_by": member_id,
        }
    )
    r = await _client.patch(
        f"/api/collections/files/records/{record_id}",
        json=body,
        headers=_headers(token, member_id, member_name),
    )
    if r.status_code != 200:
        raise ApiError(502, "could not update the file")
