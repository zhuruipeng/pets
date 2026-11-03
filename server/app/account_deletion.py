"""Account erasure is the explicit exception to ordinary sync soft deletion."""
from __future__ import annotations

import logging
import re

from fastapi import APIRouter, Depends, Header, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy import delete, or_, select, update
from sqlalchemy.orm import Session

from .auth import _bearer_token, _resolve_token
from .changes import latest_change, lock_sync_writes, member_payload, record_change
from .config import Settings, get_settings
from .db import get_session
from .models import (Attachment, AuthToken, DeletedSession, ErasedIdentity, Member,
                     PendingMediaDeletion, Pet, PetRecord, PetTag, PhotoBlob,
                     Reminder, ReminderLog, SyncChange, User, VerifyCode,
                     WalkPoint, WalkSession)
from .sync_logic import hash_token, now_ms
from .privacy import DELETED_ACTOR, anonymize_attribution

router = APIRouter(tags=["account"])
log = logging.getLogger(__name__)


class DeleteAccountIn(BaseModel):
    confirmation: str = Field(pattern="^DELETE$")


def purge_pending_media(session: Session, settings: Settings) -> None:
    """Retryable after commit and at startup; never unlink an arbitrary path."""
    lock_sync_writes(session)
    session.execute(delete(DeletedSession).where(DeletedSession.expires_at <= now_ms()))
    root = settings.media_directory.resolve()
    for item in session.execute(select(PendingMediaDeletion)).scalars().all():
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", item.attachment_id) or not re.fullmatch(r"[a-f0-9]{64}", item.sha256):
            log.error("Invalid queued media deletion")
            continue
        path = root / item.attachment_id / item.sha256
        try:
            if not path.resolve().is_relative_to(root):
                continue
            # A newly authorized upload with the same content must not be erased.
            if session.get(PhotoBlob, (item.attachment_id, item.sha256)) is None:
                path.unlink(missing_ok=True)
            session.delete(item)
        except OSError:
            log.exception("Account media cleanup will be retried")
    session.commit()


@router.delete("/me")
def delete_account(
    payload: DeleteAccountIn,
    authorization: str | None = Header(default=None),
    session: Session = Depends(get_session),
    settings: Settings = Depends(get_settings),
) -> dict:
    lock_sync_writes(session)
    now = now_ms()
    # Only this token hash, never the profile or user ID, survives for 24 hours.
    raw = _bearer_token(authorization)
    receipt = session.get(DeletedSession, hash_token(raw))
    if receipt is not None and receipt.expires_at > now:
        session.rollback()
        try:
            purge_pending_media(session, settings)
        except Exception:
            session.rollback()
            log.exception("Account deletion receipt confirmed; media cleanup will retry")
        return {"ok": True}
    _, user = _resolve_token(session, authorization)
    user_id = user.id

    own_ids = set(session.execute(select(Pet.id).where(Pet.created_by == user_id)).scalars())
    own_ids.update(session.execute(select(Member.pet_id).where(
        Member.user_id == user_id, Member.role == "owner",
        Member.status == "active", Member.deleted_at.is_(None))).scalars())
    blockers = session.execute(select(Pet.name).where(
        Pet.id.in_(own_ids), Pet.deleted_at.is_(None),
        Pet.id.in_(select(Member.pet_id).where(Member.user_id != user_id,
            Member.status == "active", Member.deleted_at.is_(None))))).scalars().all()
    if blockers:
        raise HTTPException(409, detail="account_has_shared_pets")

    # Remove all historical snapshots for private pets, and all profile snapshots.
    session.execute(delete(SyncChange).where(or_(SyncChange.pet_id.in_(own_ids),
        (SyncChange.table_name == "users") & (SyncChange.row_id == user_id))))
    leaving = session.execute(select(Member).where(or_(
        Member.pet_id.in_(own_ids), Member.user_id == user_id))).scalars().all()
    for member in leaving:
        session.execute(delete(SyncChange).where(SyncChange.table_name == "members",
                                                SyncChange.row_id == member.id))
        member.deleted_at = now
        record_change(session, table_name="members", row_id=member.id, op="delete",
            pet_id=member.pet_id, user_id=DELETED_ACTOR,
            payload=member_payload(member, now), changed_at=now)
    session.flush()

    # Shared care facts belong to the pet. Erase attribution, preserve the facts,
    # and append fresh snapshots so already-synced devices see anonymization.
    latest = {}
    for change in session.execute(select(SyncChange).where(or_(
            SyncChange.user_id == user_id,
            SyncChange.payload["created_by"].as_string() == user_id))
            .order_by(SyncChange.seq)).scalars():
        body = dict(change.payload or {})
        if body.get("created_by") == user_id:
            body = anonymize_attribution(body)
            change.payload = body
            latest[(change.table_name, change.row_id)] = change
        if change.user_id == user_id:
            change.user_id = DELETED_ACTOR
    for change in latest.values():
        canonical = latest_change(session, change.table_name, change.row_id)
        if canonical.seq != change.seq:
            continue
        stamp = max(now, change.changed_at + 1, int(change.payload.get("updated_at") or 0) + 1)
        body = {**change.payload, "updated_at": stamp}
        record_change(session, table_name=change.table_name, row_id=change.row_id,
            op=change.op, pet_id=change.pet_id, user_id=DELETED_ACTOR,
            payload=body, changed_at=stamp)
    for record in session.execute(select(PetRecord).where(PetRecord.created_by == user_id)).scalars():
        record.created_by = DELETED_ACTOR
        record.payload = anonymize_attribution({"payload": record.payload}).get("payload")
    session.execute(update(WalkSession).where(WalkSession.created_by == user_id)
                    .values(created_by=DELETED_ACTOR))

    for blob in session.execute(select(PhotoBlob).where(PhotoBlob.pet_id.in_(own_ids))).scalars():
        session.merge(PendingMediaDeletion(attachment_id=blob.attachment_id, sha256=blob.sha256))
    session.flush()
    record_ids = select(PetRecord.id).where(PetRecord.pet_id.in_(own_ids))
    reminder_ids = select(Reminder.id).where(Reminder.pet_id.in_(own_ids))
    walk_ids = select(WalkSession.id).where(WalkSession.pet_id.in_(own_ids))
    for model, condition in (
        (PhotoBlob, PhotoBlob.pet_id.in_(own_ids)),
        (Attachment, Attachment.record_id.in_(record_ids)),
        (ReminderLog, ReminderLog.reminder_id.in_(reminder_ids)),
        (WalkPoint, WalkPoint.session_id.in_(walk_ids)),
        (Reminder, Reminder.pet_id.in_(own_ids)),
        (WalkSession, WalkSession.pet_id.in_(own_ids)),
        (PetTag, PetTag.pet_id.in_(own_ids)),
        (PetRecord, PetRecord.pet_id.in_(own_ids)),
        (Member, or_(Member.pet_id.in_(own_ids), Member.user_id == user_id)),
        (Pet, Pet.id.in_(own_ids)),
        (AuthToken, AuthToken.user_id == user_id),
        (VerifyCode, or_(VerifyCode.target == user.phone if user.phone else False,
                         VerifyCode.target == user.email if user.email else False)),
        (User, User.id == user_id),
    ):
        session.execute(delete(model).where(condition).execution_options(synchronize_session=False))
    session.execute(delete(DeletedSession).where(DeletedSession.expires_at <= now))
    session.merge(ErasedIdentity(id_hash=hash_token(user_id)))
    session.add(DeletedSession(token=hash_token(raw), expires_at=now + 86_400_000))
    session.commit()
    session.expire_all()
    try:
        purge_pending_media(session, settings)
    except Exception:
        session.rollback()
        log.exception("Committed account erasure; media cleanup will retry at startup")
    return {"ok": True}
