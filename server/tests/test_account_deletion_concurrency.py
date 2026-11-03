"""The erasure transaction and queued authenticated writes share one PG lock."""
from concurrent.futures import ThreadPoolExecutor, TimeoutError
import threading

import pytest
from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.orm import Session
from starlette.requests import Request

from app import account_deletion
from app.account_deletion import DeleteAccountIn, delete_account
from app.auth import current_user
from app.config import Settings
from app.models import AuthToken, Member, Pet, SyncChange, User
from app.sync import PushChangeIn, PushIn, sync_push
from app.sync_logic import hash_token, now_ms
from test_sync_concurrency import pg_engine


def test_erasure_blocks_queued_write_and_removes_committed_data(pg_engine, tmp_path, monkeypatch):
    with Session(pg_engine) as session:
        session.add(AuthToken(token=hash_token('real-token'), user_id='u1',
            created_at=now_ms(), expires_at=now_ms() + 60_000))
        session.add(Pet(id='owned', name='pet', species='cat', created_by='u1',
                        created_at=1, updated_at=1))
        session.flush()
        session.add(Member(id='owner-member', pet_id='owned', user_id='u1',
                            role='owner', status='active', joined_at=1))
        session.commit()
    entered, release, writer_started = threading.Event(), threading.Event(), threading.Event()
    original = account_deletion._resolve_token
    def pause(*args, **kwargs):
        result = original(*args, **kwargs)
        entered.set()
        assert release.wait(5)
        return result
    monkeypatch.setattr(account_deletion, '_resolve_token', pause)

    def erase():
        with Session(pg_engine, autoflush=False) as session:
            return delete_account(DeleteAccountIn(confirmation='DELETE'),
                authorization='Bearer real-token', session=session,
                settings=Settings(media_directory=tmp_path))

    def write():
        with Session(pg_engine, autoflush=False) as session:
            writer_started.set()
            # Auth for a queued mutation must resolve AFTER deletion releases
            # its transaction, even though the HTTP request started earlier.
            user = current_user(Request({'type':'http', 'method':'POST'}),
                authorization='Bearer real-token', session=session)
            return sync_push(PushIn(changes=[PushChangeIn(table='records',
                row_id='late-record', updated_at=now_ms(), payload={
                    'pet_id':'owned','type':'note','recorded_at':1,'created_at':1})]),
                session=session, user=user)

    with ThreadPoolExecutor(max_workers=2) as pool:
        deleting = pool.submit(erase)
        assert entered.wait(5)
        writing = pool.submit(write)
        assert writer_started.wait(5)
        try:
            with pytest.raises(TimeoutError):
                writing.result(timeout=0.1)
        finally:
            release.set()
        assert deleting.result(timeout=5) == {'ok':True}
        with pytest.raises(HTTPException) as rejected:
            writing.result(timeout=5)
        assert rejected.value.status_code == 401
    with Session(pg_engine) as session:
        assert session.get(User,'u1') is None
        assert session.get(Pet,'owned') is None
        assert not session.execute(select(SyncChange).where(
            SyncChange.row_id == 'late-record')).scalars().all()


def test_erasure_anonymizes_shared_snapshots_on_postgres(pg_engine, tmp_path):
    with Session(pg_engine, autoflush=False, expire_on_commit=False) as session:
        session.add(User(id='u2', nickname='owner', region='intl', created_at=1, updated_at=1))
        session.flush()
        session.add(Pet(id='shared', name='pet', species='cat', created_by='u2',
                        created_at=1, updated_at=1))
        session.flush()
        session.add_all([
            AuthToken(token=hash_token('member-token'), user_id='u1',
                      created_at=now_ms(), expires_at=now_ms() + 60_000),
            Member(id='u1-member',pet_id='shared',user_id='u1',role='editor',status='active',joined_at=1),
            Member(id='u2-member',pet_id='shared',user_id='u2',role='owner',status='active',joined_at=1),
        ])
        session.commit()
        sync_push(PushIn(changes=[PushChangeIn(table='records', row_id='shared-record',
            updated_at=10, payload={'pet_id':'shared','created_by':'u1',
                'type':'note','recorded_at':1,'created_at':1})]),
            user=session.get(User,'u1'),session=session)
        assert delete_account(DeleteAccountIn(confirmation='DELETE'),
            authorization='Bearer member-token',session=session,
            settings=Settings(media_directory=tmp_path)) == {'ok':True}
        assert session.get(User,'u1') is None
        assert session.get(Pet,'shared').created_by == 'u2'
        snapshots=session.execute(select(SyncChange).where(
            SyncChange.row_id == 'shared-record')).scalars().all()
        assert len(snapshots) == 2
        assert all(c.payload['created_by'] == 'deleted-user' for c in snapshots)
