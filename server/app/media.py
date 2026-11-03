"""Authenticated, immutable photos stored only in this deployment's region."""
from __future__ import annotations

import hashlib
import os
import re
import tempfile
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from fastapi.responses import FileResponse
from sqlalchemy import select
from sqlalchemy.orm import Session

from .auth import current_user
from .changes import latest_change, lock_sync_writes
from .config import Settings, get_settings
from .db import get_session
from .members import _require_role
from .models import Pet, PhotoBlob, User
from .sync_logic import now_ms

router = APIRouter(tags=["photos"])
_ID = re.compile(r"^[A-Za-z0-9_-]{1,128}$")
_HASH = re.compile(r"^[a-f0-9]{64}$")


def photo_path(attachment_id: str, digest: str) -> str:
    return f"/media/photos/{attachment_id}/{digest}"


def _validate_id(value: str) -> None:
    if not _ID.fullmatch(value):
        raise HTTPException(422, "invalid photo id")


def _require_parent(session: Session, pet_id: str, record_id: str, user: User,
                    action: str) -> None:
    _require_role(session, pet_id, user, action)
    pet = session.get(Pet, pet_id)
    parent = latest_change(session, "records", record_id)
    if (pet is None or pet.deleted_at is not None or parent is None
            or parent.pet_id != pet_id or parent.op == "delete"
            or (parent.payload or {}).get("deleted_at") is not None):
        raise HTTPException(404, "photo parent unavailable")


def _image_type(header: bytes) -> str:
    if header.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if header.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if header.startswith((b"GIF87a", b"GIF89a")):
        return "image/gif"
    if header[:4] == b"RIFF" and header[8:12] == b"WEBP":
        return "image/webp"
    if header[4:8] == b"ftyp" and header[8:12] in (
            b"heic", b"heix", b"hevc", b"hevx", b"mif1", b"msf1"):
        return "image/heic"
    raise HTTPException(415, "unsupported photo format")


def validated_photo_url(session: Session, attachment_id: str, pet_id: str,
                        record_id: str, value: object) -> bool:
    """A sync row may reference only a verified upload for its own parent."""
    if not isinstance(value, str):
        return False
    prefix = f"/media/photos/{attachment_id}/"
    if not value.startswith(prefix) or not _HASH.fullmatch(value[len(prefix):]):
        return False
    blob = session.get(PhotoBlob, (attachment_id, value[len(prefix):]))
    return blob is not None and blob.pet_id == pet_id and blob.record_id == record_id


@router.put("/media/photos/{attachment_id}")
async def upload_photo(
    attachment_id: str, request: Request,
    pet_id: str = Query(min_length=1, max_length=128),
    record_id: str = Query(min_length=1, max_length=128),
    user: User = Depends(current_user), session: Session = Depends(get_session),
    settings: Settings = Depends(get_settings),
) -> dict:
    _validate_id(attachment_id)
    _require_parent(session, pet_id, record_id, user, "write_data")
    # Release the initial read transaction before receiving a slow upload.
    session.rollback()
    root = settings.media_directory.resolve()
    root.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        digest, count, header = hashlib.sha256(), 0, b""
        with tempfile.NamedTemporaryFile(dir=root, prefix="upload-", delete=False) as target:
            temporary = Path(target.name)
            async for chunk in request.stream():
                count += len(chunk)
                if count > settings.photo_max_bytes:
                    raise HTTPException(413, "photo exceeds size limit")
                header = (header + chunk)[:32] if len(header) < 32 else header
                digest.update(chunk)
                target.write(chunk)
        content_type = _image_type(header)
        checksum = digest.hexdigest()
        lock_sync_writes(session)
        session.expire_all()
        _require_parent(session, pet_id, record_id, user, "write_data")
        existing = latest_change(session, "attachments", attachment_id)
        blobs = session.execute(select(PhotoBlob).where(
            PhotoBlob.attachment_id == attachment_id)).scalars().all()
        if ((existing is not None and (existing.pet_id != pet_id
                or (existing.payload or {}).get("record_id") != record_id))
                or any(b.pet_id != pet_id or b.record_id != record_id for b in blobs)):
            raise HTTPException(403, "photo belongs to another record")
        if existing is not None and (existing.op == "delete"
                or (existing.payload or {}).get("deleted_at") is not None):
            raise HTTPException(409, "photo was deleted")
        blob = session.get(PhotoBlob, (attachment_id, checksum))
        if blob is None:
            blob = PhotoBlob(attachment_id=attachment_id, sha256=checksum,
                pet_id=pet_id, record_id=record_id, content_type=content_type,
                size_bytes=count, created_at=now_ms())
            session.add(blob)
        folder = root / attachment_id
        folder.mkdir(exist_ok=True)
        # Content-addressed names make a retry and concurrent identical uploads safe.
        os.replace(temporary, folder / checksum)
        temporary = None
        session.commit()
        return {"remote_url": photo_path(attachment_id, checksum),
                "sha256": checksum, "size_bytes": count}
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


@router.get("/media/photos/{attachment_id}/{digest}")
def download_photo(
    attachment_id: str, digest: str,
    user: User = Depends(current_user), session: Session = Depends(get_session),
    settings: Settings = Depends(get_settings),
) -> FileResponse:
    _validate_id(attachment_id)
    if not _HASH.fullmatch(digest):
        raise HTTPException(422, "invalid photo hash")
    blob = session.get(PhotoBlob, (attachment_id, digest))
    if blob is None:
        raise HTTPException(404, "photo not found")
    _require_parent(session, blob.pet_id, blob.record_id, user, "read")
    row = latest_change(session, "attachments", attachment_id)
    if row is not None and (row.op == "delete"
            or (row.payload or {}).get("deleted_at") is not None):
        raise HTTPException(404, "photo was deleted")
    path = settings.media_directory.resolve() / attachment_id / digest
    if not path.is_file():
        raise HTTPException(404, "photo file unavailable")
    return FileResponse(path, media_type=blob.content_type,
        headers={"Cache-Control": "private, no-store", "X-Content-Type-Options": "nosniff"})
