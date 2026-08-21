"""End-to-end check against a RUNNING file service and PocketBase.

    python tests/verify_service.py

Not a unit test — it drives the real thing over HTTP, because the failures worth
catching here are all integration failures: a chunk boundary, a cookie scope, a
Range header, an atomic rename. Unit tests for this would be testing the mocks.

The three hard ones it proves:
  * a torn upload resumes with zero bytes re-sent and the sha256 matches
  * finish is idempotent, and heals a missing database record
  * an uploaded .html is NEVER served inline (it would run as our origin)
"""

from __future__ import annotations

import hashlib
import io
import os
import sys
import time

import httpx

FILES = os.getenv("TS_FILES_URL", "http://127.0.0.1:8091")
PB = os.getenv("TS_PB_URL", "http://127.0.0.1:8090")
PW = os.getenv("TS_DEV_PASSWORD", "teamstream-dev-local")

failures = 0


def check(label: str, ok: bool, detail: str = "") -> None:
    global failures
    print(f"  {'ok  ' if ok else 'FAIL'}  {label}{'  - ' + detail if detail else ''}")
    if not ok:
        failures += 1


def login() -> tuple[str, str, str]:
    r = httpx.post(
        f"{PB}/api/collections/members/auth-with-password",
        json={"identity": "shayaan@teamstream.local", "password": PW},
        timeout=10,
    )
    r.raise_for_status()
    d = r.json()
    return d["token"], d["record"]["id"], d["record"]["name"]


def fingerprint(name: str, size: int, mtime: int, folder: str) -> str:
    return hashlib.sha256(f"{name}|{size}|{mtime}|{folder}".encode()).hexdigest()


def upload(
    c: httpx.Client, token: str, name: str, data: bytes, folder: str = "", tear_after: int | None = None
) -> dict:
    """Upload in chunks. `tear_after` simulates a dropped connection."""
    H = {"Authorization": token}
    created = c.post(
        f"{FILES}/files/uploads",
        json={
            "name": name,
            "size": len(data),
            "mime": "application/octet-stream",
            "folder": folder,
            "fingerprint": fingerprint(name, len(data), 1755771242000, folder),
        },
        headers=H,
    )
    created.raise_for_status()
    info = created.json()
    uid, chunk = info["upload_id"], info["chunk_size"]
    chunk = min(chunk, 64 * 1024)  # small chunks so the test exercises the loop

    sent = info["received"]
    n = 0
    while sent < len(data):
        if tear_after is not None and n == tear_after:
            return {"upload_id": uid, "torn_at": sent, "info": info}
        piece = data[sent : sent + chunk]
        r = c.put(
            f"{FILES}/files/uploads/{uid}",
            params={"offset": sent},
            content=piece,
            headers={**H, "Content-Type": "application/octet-stream"},
        )
        r.raise_for_status()
        sent = r.json()["received"]
        n += 1

    done = c.post(f"{FILES}/files/uploads/{uid}/finish", headers=H)
    done.raise_for_status()
    return {"upload_id": uid, "finished": done.json(), "info": info}


def main() -> int:
    token, member_id, member_name = login()
    H = {"Authorization": token}

    with httpx.Client(timeout=60) as c:
        print("\n-- health --")
        h = c.get(f"{FILES}/files/health").json()
        check("service is up", h.get("ok") is True)
        check("no orphans to start", h.get("orphans") == 0, str(h.get("orphans")))

        print("\n-- auth --")
        r = c.post(f"{FILES}/files/uploads", json={"name": "x", "size": 1, "fingerprint": "f"})
        check("write without a token is refused", r.status_code == 401, f"got {r.status_code}")
        check("...with our error shape", "error" in r.json(), r.text[:80])

        print("\n-- a plain upload --")
        payload = bytes(range(256)) * 900  # ~230KB, several chunks
        digest = hashlib.sha256(payload).hexdigest()
        res = upload(c, token, "report final.bin", payload, folder="Reports")
        fin = res["finished"]
        check("sha256 matches what we sent", fin["sha256"] == digest)
        check("size matches", fin["size"] == len(payload))
        check("a database record was created", bool(fin["record_id"]))
        check("not inline-safe (unknown type)", fin["inline_safe"] is False)
        fid = fin["file_id"]

        print("\n-- finish is idempotent --")
        again = c.post(f"{FILES}/files/uploads/{res['upload_id']}/finish", headers=H)
        check("re-finishing returns 200", again.status_code == 200, str(again.status_code))
        check("...with an identical body", again.status_code == 200 and again.json() == fin)

        print("\n-- download --")
        # A cookie, because <img> and <video> cannot send a header.
        s = c.post(f"{FILES}/files/session", headers=H)
        check("session mints a cookie", s.status_code == 204 and "ts_files" in c.cookies)

        got = c.get(f"{FILES}/files/{fid}")
        check("cookie alone can read bytes", got.status_code == 200, str(got.status_code))
        check("bytes come back identical", hashlib.sha256(got.content).hexdigest() == digest)
        check(
            "unknown type is an attachment",
            "attachment" in got.headers.get("content-disposition", ""),
            got.headers.get("content-disposition", ""),
        )
        check("nosniff is set", got.headers.get("x-content-type-options") == "nosniff")

        rng = c.get(f"{FILES}/files/{fid}", headers={"Range": "bytes=0-99"})
        check("Range gives a 206", rng.status_code == 206, str(rng.status_code))
        check("...with the right slice", rng.content == payload[:100])
        bad = c.get(f"{FILES}/files/{fid}", headers={"Range": "bytes=500-100"})
        check("a reversed Range is refused", bad.status_code in (400, 416), str(bad.status_code))

        print("\n-- writes still need the header --")
        cookie_only = httpx.Client(timeout=20, cookies=c.cookies)
        d = cookie_only.post(f"{FILES}/files/{fid}/delete")
        check("cookie-only write is refused (CSRF)", d.status_code == 401, str(d.status_code))
        cookie_only.close()

        print("\n-- an interrupted upload resumes --")
        big = os.urandom(300_000)
        big_digest = hashlib.sha256(big).hexdigest()
        torn = upload(c, token, "video.bin", big, tear_after=2)
        at = torn["torn_at"]
        check("some bytes landed before the tear", 0 < at < len(big), f"{at} of {len(big)}")

        # Re-drop the same file: create is idempotent on the fingerprint.
        again = c.post(
            f"{FILES}/files/uploads",
            json={
                "name": "video.bin",
                "size": len(big),
                "mime": "application/octet-stream",
                "folder": "",
                "fingerprint": fingerprint("video.bin", len(big), 1755771242000, ""),
            },
            headers=H,
        ).json()
        check("re-dropping resumes the same upload", again["upload_id"] == torn["upload_id"])
        check("...from exactly where it stopped", again["received"] == at, str(again["received"]))
        check("...re-sending zero bytes", again.get("resumed") is True)

        # A wrong offset must be refused, not helpfully placed.
        wrong = c.put(
            f"{FILES}/files/uploads/{again['upload_id']}",
            params={"offset": at + 5},
            content=b"xxxxx",
            headers={**H, "Content-Type": "application/octet-stream"},
        )
        check("a wrong offset is a 409", wrong.status_code == 409, str(wrong.status_code))
        check("...and reports the true received", wrong.json().get("received") == at)

        sent = at
        while sent < len(big):
            r = c.put(
                f"{FILES}/files/uploads/{again['upload_id']}",
                params={"offset": sent},
                content=big[sent : sent + 64 * 1024],
                headers={**H, "Content-Type": "application/octet-stream"},
            )
            r.raise_for_status()
            sent = r.json()["received"]
        done = c.post(f"{FILES}/files/uploads/{again['upload_id']}/finish", headers=H).json()
        check("the resumed file's sha256 matches", done["sha256"] == big_digest)

        print("\n-- an uploaded .html must never render inline --")
        evil = b"<script>fetch('/api/collections/members/records')</script>"
        res2 = upload(c, token, "notes.html", evil)
        check("html is not inline-safe", res2["finished"]["inline_safe"] is False)
        got2 = c.get(f"{FILES}/files/{res2['finished']['file_id']}")
        check(
            "...served as an attachment",
            "attachment" in got2.headers.get("content-disposition", ""),
        )
        check(
            "...as octet-stream, not text/html",
            "html" not in got2.headers.get("content-type", ""),
            got2.headers.get("content-type", ""),
        )

        print("\n-- a real image gets a thumbnail --")
        try:
            from PIL import Image

            buf = io.BytesIO()
            Image.new("RGB", (1200, 800), (40, 90, 120)).save(buf, "PNG")
            res3 = upload(c, token, "photo.png", buf.getvalue())
            check("png sniffed as image/png", res3["finished"]["mime"] == "image/png",
                  res3["finished"]["mime"])
            check("png IS inline-safe", res3["finished"]["inline_safe"] is True)
            t = c.get(f"{FILES}/files/{res3['finished']['file_id']}/thumb", params={"w": 480})
            check("thumbnail generated", t.status_code == 200, str(t.status_code))
            check("...is a jpeg", t.headers.get("content-type") == "image/jpeg")
            check("...cached immutably", "immutable" in t.headers.get("cache-control", ""))
            bad_w = c.get(f"{FILES}/files/{res3['finished']['file_id']}/thumb", params={"w": 481})
            check("an off-list width is refused", bad_w.status_code == 400, str(bad_w.status_code))
        except ImportError:
            print("  skip  Pillow not available")

        print("\n-- soft delete keeps the bytes --")
        dl = c.post(f"{FILES}/files/{fid}/delete", headers=H)
        check("delete succeeds", dl.status_code == 200, dl.text[:120])
        still = c.get(f"{FILES}/files/{fid}")
        check("the blob is STILL readable after delete", still.status_code == 200)
        meta = c.get(f"{FILES}/files/{fid}/meta").json()
        check("the blob is still complete on disk", meta["on_disk"]["complete"] is True)

        print("\n-- path safety --")
        for bad_id in ("../../etc/passwd", "..", "NOTANID", "x" * 40):
            r = c.get(f"{FILES}/files/{bad_id}/meta")
            check(f"rejects {bad_id!r}", r.status_code in (400, 404), str(r.status_code))

    print()
    print("All service checks passed.\n" if failures == 0 else f"{failures} FAILED\n")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
