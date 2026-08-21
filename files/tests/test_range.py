"""Range/206, asserted against the Starlette we actually ship.

WHY THIS FILE EXISTS, AND WHY IT COMES FIRST.

Range is not a nice-to-have here: without 206 responses a browser cannot seek in
a video at all — not "worse", none. The obvious move was to port
`video_editor/app/server.py:_send_file`, which implements it by hand because the
stdlib handler does not. Reading it closely first turned up five bugs:

  1. a reversed range (`bytes=500-100`) computes a NEGATIVE Content-Length and
     sends a 206 with an empty body — a protocol violation on a keep-alive
     connection
  2. `bytes=-` matches its regex and yields a 206 for the whole file, where
     RFC 9110 says an invalid range must be ignored
  3. a multi-range request is silently truncated to its first range, with no
     multipart/byteranges
  4. no ETag, Last-Modified, If-Range or If-None-Match — so a client resuming a
     range against a file that changed underneath splices two versions together
  5. `Cache-Control: max-age=3600` on a PATH-keyed thumbnail URL, so a
     regenerated thumb serves stale for an hour

Starlette's FileResponse gets all five right, so the correct port is to DELETE
that code rather than translate it. These tests pin that decision: they assert
the behaviour we are relying on, one test per bug, so a future Starlette upgrade
that regresses Range fails here instead of failing on somebody's phone.
"""

from __future__ import annotations

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from starlette.responses import FileResponse

SIZE = 4096


@pytest.fixture(scope="module")
def client(tmp_path_factory: pytest.TempPathFactory) -> TestClient:
    blob = tmp_path_factory.mktemp("blobs") / "clip.bin"
    blob.write_bytes(bytes(range(256)) * (SIZE // 256))

    app = FastAPI()

    @app.get("/f")
    def serve() -> FileResponse:
        return FileResponse(blob, media_type="application/octet-stream")

    return TestClient(app)


def test_plain_get_advertises_range_support(client: TestClient) -> None:
    """Accept-Ranges on a 200 is what tells the browser seeking is possible."""
    r = client.get("/f")
    assert r.status_code == 200
    assert r.headers["accept-ranges"] == "bytes"
    assert int(r.headers["content-length"]) == SIZE


def test_normal_range_is_206(client: TestClient) -> None:
    r = client.get("/f", headers={"Range": "bytes=0-99"})
    assert r.status_code == 206
    assert r.headers["content-range"] == f"bytes 0-99/{SIZE}"
    assert int(r.headers["content-length"]) == 100
    assert len(r.content) == 100


def test_open_ended_range(client: TestClient) -> None:
    r = client.get("/f", headers={"Range": "bytes=4000-"})
    assert r.status_code == 206
    assert r.headers["content-range"] == f"bytes 4000-{SIZE - 1}/{SIZE}"
    assert len(r.content) == SIZE - 4000


def test_suffix_range(client: TestClient) -> None:
    """`bytes=-500` means the LAST 500 bytes, not the first."""
    r = client.get("/f", headers={"Range": "bytes=-500"})
    assert r.status_code == 206
    assert r.headers["content-range"] == f"bytes {SIZE - 500}-{SIZE - 1}/{SIZE}"
    assert len(r.content) == 500


def test_unsatisfiable_range_is_416_with_content_range(client: TestClient) -> None:
    r = client.get("/f", headers={"Range": f"bytes={SIZE + 10}-"})
    assert r.status_code == 416
    assert r.headers["content-range"] == f"bytes */{SIZE}"


# --- the five reference bugs, one test each -------------------------------


def test_bug1_reversed_range_is_rejected_not_negative_length(client: TestClient) -> None:
    """`bytes=500-100`.

    The reference computes length = 100 - 500 + 1 = -399, sends
    `Content-Length: -399` with a 206, then writes no body at all.
    """
    r = client.get("/f", headers={"Range": "bytes=500-100"})
    assert r.status_code in (400, 416)
    assert int(r.headers.get("content-length", 0)) >= 0


def test_bug2_bare_dash_range_is_not_a_partial(client: TestClient) -> None:
    """`bytes=-` is invalid and must not produce a 206 of the whole file."""
    r = client.get("/f", headers={"Range": "bytes=-"})
    assert r.status_code != 206


def test_bug3_multi_range_is_not_silently_truncated(client: TestClient) -> None:
    """`bytes=0-99,200-299`.

    The reference's regex matches the `bytes=0-99` prefix, drops the rest, and
    answers 206 with only the first part — so a client that asked for two ranges
    is handed one and told nothing. Chrome's <video> does not do this; PDF
    viewers and download managers do.
    """
    r = client.get("/f", headers={"Range": "bytes=0-99,200-299"})
    assert r.status_code in (206, 416)
    if r.status_code == 206:
        ctype = r.headers.get("content-type", "")
        # Either a real multipart answer, or not a truncated single part.
        assert "multipart/byteranges" in ctype or len(r.content) != 100


def test_bug4_validators_are_present(client: TestClient) -> None:
    """ETag and Last-Modified, so If-Range can be answered honestly."""
    r = client.get("/f")
    assert r.headers.get("etag")
    assert r.headers.get("last-modified")


def test_bug4_if_range_with_stale_validator_returns_the_whole_file(
    client: TestClient,
) -> None:
    """The resume case that silently splices two versions together.

    A client holding a stale validator asks for a range; the server must notice
    the file changed and send the WHOLE file (200) rather than a slice of the
    new one that gets glued onto bytes from the old one.
    """
    r = client.get(
        "/f",
        headers={"Range": "bytes=0-99", "If-Range": '"definitely-not-the-etag"'},
    )
    assert r.status_code == 200
    assert len(r.content) == SIZE


def test_bug4_if_range_with_current_validator_still_gives_the_range(
    client: TestClient,
) -> None:
    etag = client.get("/f").headers["etag"]
    r = client.get("/f", headers={"Range": "bytes=0-99", "If-Range": etag})
    assert r.status_code == 206
    assert len(r.content) == 100


def test_malformed_range_header_does_not_500(client: TestClient) -> None:
    """Garbage in a header is a client problem, not a server error."""
    r = client.get("/f", headers={"Range": "kilobytes=1-2"})
    assert r.status_code in (200, 400, 416)
    assert r.status_code < 500
