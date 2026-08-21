"""One error shape, decided once.

Lifted from video_editor/app/server.py, whose whole error strategy is: domain
code raises ValueError with a human sentence and never touches HTTP; one handler
turns that into `{"error": "..."}` with a 400; one `unwrap()` on the client turns
it into `throw new Error(msg)`; one `catch` shows it. Twenty lines across the
stack, and it is why that codebase has no error-code taxonomy anywhere.

The detail that is easy to miss when porting it to FastAPI: **FastAPI's own
defaults emit `{"detail": ...}`**, not `{"error": ...}`. Both HTTPException and
RequestValidationError need overriding too, or the client has to unwrap two
shapes — which defeats the entire point of unwrapping once.
"""

from __future__ import annotations

import logging

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

log = logging.getLogger("teamstream.files")


class ApiError(Exception):
    """An error with a status we chose and a sentence a person can read."""

    def __init__(self, status: int, message: str, **extra: object) -> None:
        super().__init__(message)
        self.status = status
        self.message = message
        # e.g. the true `received` on a 409, so the client can re-slice without
        # a second round trip.
        self.extra = extra


def _body(message: str, **extra: object) -> dict[str, object]:
    return {"error": message, **extra}


def install(app: FastAPI) -> None:
    @app.exception_handler(ApiError)
    async def _api_error(_: Request, exc: ApiError) -> JSONResponse:
        return JSONResponse(_body(exc.message, **exc.extra), status_code=exc.status)

    @app.exception_handler(ValueError)
    async def _value_error(_: Request, exc: ValueError) -> JSONResponse:
        return JSONResponse(_body(str(exc)), status_code=400)

    @app.exception_handler(FileNotFoundError)
    async def _not_found(_: Request, exc: FileNotFoundError) -> JSONResponse:
        return JSONResponse(_body(str(exc) or "not found"), status_code=404)

    @app.exception_handler(StarletteHTTPException)
    async def _http(_: Request, exc: StarletteHTTPException) -> JSONResponse:
        return JSONResponse(_body(str(exc.detail)), status_code=exc.status_code)

    @app.exception_handler(RequestValidationError)
    async def _validation(_: Request, exc: RequestValidationError) -> JSONResponse:
        # Flatten FastAPI's nested validation report into one sentence. The
        # client shows this string directly, and "body -> size: Input should be
        # a valid integer" is more use to a person than a JSON tree.
        first = exc.errors()[0] if exc.errors() else None
        if first:
            where = " -> ".join(str(p) for p in first.get("loc", ()) if p != "body")
            msg = first.get("msg", "invalid request")
            text = f"{where}: {msg}" if where else str(msg)
        else:
            text = "invalid request"
        return JSONResponse(_body(text), status_code=400)

    @app.exception_handler(Exception)
    async def _unexpected(request: Request, exc: Exception) -> JSONResponse:
        # Logged with a traceback, reported without one: the traceback is for
        # us, and a stack trace in an error toast tells the user nothing.
        log.exception("unhandled error on %s %s", request.method, request.url.path)
        return JSONResponse(_body("Something went wrong."), status_code=500)
