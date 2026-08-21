"""Ids, filenames and containment — the three ways a path can go wrong.

Three independent layers, in the order they stop an attack:

  1. Ids are MINTED BY US and validated by regex before they are ever
     concatenated into a path. A client never supplies a path component.
  2. Filenames are sanitised on the way in, and re-derived from the directory
     listing on the way out — so even a corrupted meta.json cannot redirect a
     read.
  3. Every resolved path is checked for containment, which is
     video_editor's `library.resolve()` in the modern spelling.

Any one of these would probably do. All three are about fifteen lines.
"""

from __future__ import annotations

import re
import secrets
import unicodedata
from pathlib import Path

# 26 lowercase Crockford-ish base32 characters, ULID-shaped. Chosen over a UUID
# because it is filename-safe with no escaping, case-insensitive on the
# filesystems this may ever touch, and short enough to read out loud when
# somebody is looking at a directory listing over SSH.
_ALPHABET = "0123456789abcdefghjkmnpqrstvwxyz"
ID_RE = re.compile(r"^[0-9a-z]{26}$")


def mint_id() -> str:
    return "".join(secrets.choice(_ALPHABET) for _ in range(26))


def valid_id(value: str) -> str:
    """Validate an id BEFORE it becomes a path component."""
    if not ID_RE.match(value or ""):
        raise ValueError("not a valid id")
    return value


_CONTROL = dict.fromkeys(range(32))


def safe_name(name: str) -> str:
    """A filename that is only ever a filename.

    `Path(name).name` discards any directory part, including a Windows drive or
    a UNC prefix, so "../../etc/passwd" and "C:\\Windows\\win.ini" both collapse
    to their last segment. What remains is normalised, stripped of control
    characters, and capped by BYTES rather than characters — ext4's limit is 255
    bytes, and an emoji is four of them, so a character cap would still produce
    names the filesystem refuses.
    """
    base = Path(str(name or "")).name
    base = base.replace("\\", "/").rsplit("/", 1)[-1]
    base = unicodedata.normalize("NFC", base).translate(_CONTROL).strip()

    if base in {"", ".", ".."}:
        return "file"

    encoded = base.encode("utf-8")
    if len(encoded) > 200:
        stem, dot, ext = base.rpartition(".")
        ext = (dot + ext)[:32] if dot else ""
        room = 200 - len(ext.encode("utf-8"))
        trimmed = encoded[:room].decode("utf-8", "ignore") if room > 0 else "file"
        base = (trimmed or "file") + ext
    return base or "file"


def contained(root: Path, *parts: str) -> Path:
    """Resolve under `root`, refusing anything that escapes it.

    `library.resolve()`, ported. `.resolve()` first is what makes it work
    against all three real vectors: `..` is normalised away, a symlink pointing
    outside is followed and then caught, and an absolute path replaces the
    left-hand side in pathlib — landing outside `root`, where the containment
    check finds it. Many hand-rolled versions using os.path.join get that last
    one wrong.

    `is_relative_to` rather than a string startswith, so "/srv/files-evil"
    cannot pass as a child of "/srv/files".
    """
    root = root.resolve()
    target = root.joinpath(*parts).resolve()
    if target != root and not target.is_relative_to(root):
        raise ValueError("path escapes the store")
    return target


def blob_dir(root: Path, file_id: str) -> Path:
    return contained(root, "blobs", valid_id(file_id))


def upload_dir(root: Path, upload_id: str) -> Path:
    return contained(root, "tmp", valid_id(upload_id))


def thumb_dir(root: Path, file_id: str) -> Path:
    return contained(root, "thumbs", valid_id(file_id))


def stored_blob(dir_: Path) -> Path | None:
    """The one file in a blob directory that is not bookkeeping.

    Derived by listing rather than by reading `meta.json`, so a meta file that
    is corrupt, hand-edited or written by an older version can never point a
    read somewhere else.
    """
    if not dir_.is_dir():
        return None
    for child in dir_.iterdir():
        if child.is_file() and child.name not in {"meta.json", ".complete"}:
            return child
    return None
