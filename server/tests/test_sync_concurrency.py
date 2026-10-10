"""PostgreSQL-only concurrency regressions.

Set PET_TEST_POSTGRES_URL to a disposable local PostgreSQL database. Each test
creates and removes a unique schema; it never uses the application's database.
"""
from concurrent.futures import ThreadPoolExecutor, TimeoutError
import os
import threading
import uuid

import pytest
from sqlalchemy import create_engine, select, text
from sqlalchemy.orm import Session

from app import sync
from app.changes import lock_sync_writes, record_change
from app.models import Base, User, SyncChange
from app.sync import PushChangeIn, PushIn, sync_pull, sync_push


@pytest.fixture
def pg_engine():
    url = os.environ.get("PET_TEST_POSTGRES_URL")
    if not url:
        pytest.skip("PET_TEST_POSTGRES_URL not configured")
    engine = create_engine(url, isolation_level="READ COMMITTED")
    schema = "sync_test_" + uuid.uuid4().hex
    with engine.begin() as connection:
        connection.execute(text(f'CREATE SCHEMA "{schema}"'))
    scoped = engine.execution_options(schema_translate_map={None: schema})
    Base.metadata.create_all(scoped)
    with Session(scoped) as session:
        session.add(User(id="u1", nickname="user", region="intl", created_at=1, updated_at=1))
        session.commit()
    try:
        yield scoped
    finally:
        with engine.begin() as connection:
            connection.execute(text(f'DROP SCHEMA "{schema}" CASCADE'))
        engine.dispose()


def test_concurrent_lww_reads_after_previous_writer_commits(pg_engine, monkeypatch):
    entered, release = threading.Event(), threading.Event()
    second_started = threading.Event()
    original_latest = sync.latest_change
    original_lock = sync.lock_sync_writes
    def latest(session, table, row):
        result = original_latest(session, table, row)
        if threading.current_thread().name.endswith("_0"):
            entered.set()
            assert release.wait(10)
        return result
    def lock(session):
        if threading.current_thread().name.endswith("_1"):
            second_started.set()
        original_lock(session)
    monkeypatch.setattr(sync, "latest_change", latest)
    monkeypatch.setattr(sync, "lock_sync_writes", lock)
    def push(timestamp):
        with Session(pg_engine, autoflush=False, expire_on_commit=False) as session:
            return sync_push(PushIn(changes=[PushChangeIn(table="users", row_id="u1",
                updated_at=timestamp, payload={"id": "u1", "nickname": str(timestamp)})]),
                user=session.get(User, "u1"), session=session)
    with ThreadPoolExecutor(max_workers=2) as pool:
        newer = pool.submit(push, 300)
        assert entered.wait(10)
        older = pool.submit(push, 200)
        try:
            assert second_started.wait(10)
            with pytest.raises(TimeoutError):
                older.result(timeout=0.2)
        finally:
            release.set()
        assert newer.result(timeout=10)["applied"]
        loser = older.result(timeout=10)["rejected"][0]
        assert loser["result"] == "stale"
        assert loser["canonical"]["changed_at"] == 300
    with Session(pg_engine) as session:
        assert session.execute(select(SyncChange)).scalar_one().changed_at == 300


@pytest.mark.parametrize("rollback", [False, True])
def test_log_sequence_cannot_be_allocated_ahead_of_pending_commit(pg_engine, rollback):
    started = threading.Event()
    def write_second():
        with Session(pg_engine) as session:
            started.set()
            change = record_change(session, table_name="users", row_id="u1", op="upsert",
                pet_id=None, user_id="u1", payload={"id": "u1", "nickname": "second"}, changed_at=200)
            session.commit()
            return change.seq
    with Session(pg_engine, expire_on_commit=False) as first:
        lock_sync_writes(first)
        change = record_change(first, table_name="users", row_id="u1", op="upsert",
            pet_id=None, user_id="u1", payload={"id": "u1", "nickname": "first"}, changed_at=100)
        first.flush()
        first_seq = change.seq
        with ThreadPoolExecutor(max_workers=1) as pool:
            second = pool.submit(write_second)
            try:
                assert started.wait(10)
                with pytest.raises(TimeoutError):
                    second.result(timeout=0.2)
                with Session(pg_engine) as reader:
                    page = sync_pull(since=0, limit=200, table=None,
                        user=reader.get(User, "u1"), session=reader)
                    assert page["changes"] == [] and page["next_since"] == 0
            finally:
                first.rollback() if rollback else first.commit()
            assert second.result(timeout=10) > first_seq
        with Session(pg_engine) as reader:
            page = sync_pull(since=0, limit=200, table=None,
                user=reader.get(User, "u1"), session=reader)
            assert [row["payload"]["nickname"] for row in page["changes"]] == (
                ["second"] if rollback else ["first", "second"])
