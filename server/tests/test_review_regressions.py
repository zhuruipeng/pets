"""Real-session regressions for the REST and sync authorization boundaries."""

from __future__ import annotations

import pytest
import json
from fastapi.testclient import TestClient
from sqlalchemy import BigInteger, create_engine, event, select
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.ext.compiler import compiles
from sqlalchemy.orm import Session
from sqlalchemy.pool import StaticPool

from app.auth import current_user
from app.db import get_session
from app.main import app
from app.members import InviteIn, accept_invite, invite_member, remove_member
from app.models import Base, Member, Pet, SyncChange, User
from app.sync import PushChangeIn, PushIn, sync_pull, sync_push
from app.sync_logic import visible_to


@compiles(JSONB, "sqlite")
def _sqlite_jsonb(_type, _compiler, **_kwargs):
    return "JSON"


@compiles(BigInteger, "sqlite")
def _sqlite_bigint(_type, _compiler, **_kwargs):
    return "INTEGER"


@pytest.fixture
def db():
    engine = create_engine(
        "sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool
    )

    @event.listens_for(engine, "connect")
    def enable_foreign_keys(connection, _record):
        connection.execute("PRAGMA foreign_keys=ON")

    Base.metadata.create_all(engine)
    with Session(engine, autoflush=False, expire_on_commit=False) as session:
        users = [
            User(id=user_id, nickname=user_id, email=f"{user_id}@example.com",
                 region="intl", created_at=1, updated_at=1)
            for user_id in ("owner", "editor", "viewer", "outsider")
        ]
        session.add_all(users)
        session.flush()
        session.add_all([
            Pet(id="pet", name="Pet", species="dog", created_by="owner",
                created_at=1, updated_at=1),
            Pet(id="other-pet", name="Other", species="cat", created_by="outsider",
                created_at=1, updated_at=1),
        ])
        session.flush()
        session.add_all([
            Member(id=f"member-{role}", pet_id="pet", user_id=role, role=role,
                   status="active", joined_at=1)
            for role in ("owner", "editor", "viewer")
        ] + [Member(id="member-outsider", pet_id="other-pet", user_id="outsider",
                    role="owner", status="active", joined_at=1)])
        session.commit()
        yield session
    engine.dispose()


@pytest.fixture
def client(db):
    app.dependency_overrides[get_session] = lambda: db
    # No lifespan context: tests supply an isolated database instead of init_db().
    client = TestClient(app)
    yield client
    app.dependency_overrides.clear()
    client.close()


def login(db, user_id):
    app.dependency_overrides[current_user] = lambda: db.get(User, user_id)


def _care_changes(pet_id="pet", timestamp=10, due_at=9):
    course_id = "course"
    dose_id = f"dose_{course_id}_{due_at}"
    log_id = f"log_{course_id}_{due_at}"
    return [
        PushChangeIn(table="reminder_logs", row_id=log_id, op="upsert", updated_at=timestamp,
                     payload={"pet_id": pet_id, "reminder_id": course_id, "due_at": due_at,
                              "done_at": timestamp, "record_id": dose_id, "stock_used": 0.5,
                              "action": "done", "created_by": "forged", "actor_name": "Forged"}),
        PushChangeIn(table="records", row_id=dose_id, op="upsert", updated_at=timestamp,
                     payload={"pet_id": pet_id, "type": "medication", "created_at": timestamp,
                              "created_by": "forged", "recorded_at": timestamp, "payload":
                              '{"course_id":"course","due_at":' + str(due_at) + '}'}),
        PushChangeIn(table="reminders", row_id=course_id, op="upsert", updated_at=timestamp,
                     payload={"pet_id": pet_id, "title": "Medicine", "type": "medication"}),
    ]


def test_care_completion_dependency_order_actor_and_duplicate(db):
    changes = _care_changes()
    result = sync_push(PushIn(device_id="one", changes=changes), user=db.get(User, "editor"), session=db)
    assert len(result["applied"]) == 3
    log = db.execute(select(SyncChange).where(SyncChange.table_name == "reminder_logs")).scalar_one()
    assert log.payload["created_by"] == "editor"
    assert log.payload["actor_name"] == "editor"
    newer = _care_changes(timestamp=20)
    duplicate = sync_push(PushIn(device_id="two", changes=newer), user=db.get(User, "owner"), session=db)
    assert len(duplicate["applied"]) == 1  # course schedule remains ordinary LWW
    assert len(duplicate["rejected"]) == 2
    assert all(row["result"] == "stale" for row in duplicate["rejected"])
    assert db.execute(select(SyncChange).where(SyncChange.table_name == "reminder_logs")).scalar_one().payload["created_by"] == "editor"


@pytest.mark.parametrize("user_id", ["viewer", "outsider"])
def test_care_completion_requires_write_access(db, user_id):
    result = sync_push(PushIn(device_id="one", changes=_care_changes()), user=db.get(User, user_id), session=db)
    assert not result["applied"]
    assert all(row["result"] == "forbidden" for row in result["rejected"])


@pytest.mark.parametrize("field,value", [
    ("pet_id", "other-pet"), ("stock_used", -1), ("stock_used", "wrong"),
    ("stock_used", float("inf")), ("done_at", None), ("action", "unknown"),
    ("due_at", True), ("reminder_id", "missing"), ("record_id", "missing"),
])
def test_care_completion_invalid_parent_or_values_are_rejected(db, field, value):
    changes = _care_changes()
    sync_push(PushIn(device_id="one", changes=changes[1:]), user=db.get(User, "editor"), session=db)
    log = changes[0]
    log.payload[field] = value
    result = sync_push(PushIn(device_id="one", changes=[log]), user=db.get(User, "owner"), session=db)
    assert not result["applied"]
    assert result["rejected"][0]["result"] in ("invalid", "forbidden")


def test_historical_completion_does_not_invent_a_caregiver(db):
    changes = _care_changes()
    changes[0].payload["created_by"] = None
    changes[0].payload["actor_name"] = None
    result = sync_push(PushIn(device_id="one", changes=changes), user=db.get(User, "owner"), session=db)
    assert len(result["applied"]) == 3
    log = db.execute(select(SyncChange).where(SyncChange.table_name == "reminder_logs")).scalar_one()
    assert log.payload["created_by"] is None
    assert log.payload["actor_name"] is None


def test_dose_record_can_be_corrected_without_rewriting_completion_history(db):
    result = sync_push(PushIn(device_id="one", changes=_care_changes()), user=db.get(User, "editor"), session=db)
    assert len(result["applied"]) == 3
    original = db.execute(select(SyncChange).where(SyncChange.table_name == "records")).scalar_one()
    edited = PushChangeIn(table="records", row_id=original.row_id, op="upsert", updated_at=20,
                          payload={**original.payload, "recorded_at": 8})
    result = sync_push(PushIn(device_id="one", changes=[edited]), user=db.get(User, "editor"), session=db)
    assert len(result["applied"]) == 1
    log = db.execute(select(SyncChange).where(SyncChange.table_name == "reminder_logs")).scalar_one()
    assert log.payload["done_at"] == 10
    assert log.payload["stock_used"] == 0.5
    # A second completion by the same account has a different creation instant.
    duplicate = sync_push(PushIn(device_id="two", changes=_care_changes(timestamp=30)), user=db.get(User, "editor"), session=db)
    assert sum(row["result"] == "stale" for row in duplicate["rejected"]) == 2


def push(db, user_id, table, row_id, payload, timestamp=10, op="upsert"):
    return sync_push(
        PushIn(changes=[PushChangeIn(table=table, row_id=row_id, payload=payload,
                                   updated_at=timestamp, op=op)]),
        user=db.get(User, user_id), session=db,
    )


@pytest.mark.parametrize("user_id,allowed", [("owner", True), ("editor", True), ("viewer", False), ("outsider", False)])
def test_symptom_observation_uses_existing_sync_and_pet_permissions(db, user_id, allowed):
    observation = {"symptom": "vomiting", "count": 2, "appetite": "reduced",
                   "energy": "low", "stool": "soft", "medical_record_id": "visit"}
    result = push(db, user_id, "records", "observation", {
        "pet_id": "pet", "type": "symptom", "recorded_at": 8,
        "created_at": 10, "created_by": user_id, "payload": json.dumps(observation),
    })
    assert bool(result["applied"]) == allowed
    if allowed:
        saved = db.execute(select(SyncChange).where(SyncChange.row_id == "observation")).scalar_one()
        assert saved.payload["type"] == "symptom"
        assert json.loads(saved.payload["payload"]) == observation
        assert saved.payload["recorded_at"] == 8
    else:
        assert result["rejected"][0]["result"] == "forbidden"
        assert db.execute(select(SyncChange).where(SyncChange.row_id == "observation")).first() is None


def test_restored_completion_keeps_backup_caregiver_without_claiming_the_importer_performed_care(db):
    changes = _care_changes()
    changes[0].payload.update(created_by=None, actor_name="Original caregiver")
    details = json.loads(changes[1].payload["payload"])
    details["backup_actor_name"] = "Original caregiver"
    changes[1].payload["payload"] = json.dumps(details)
    result = sync_push(PushIn(changes=changes), user=db.get(User, "owner"), session=db)
    assert len(result["applied"]) == 3
    log = db.execute(select(SyncChange).where(SyncChange.table_name == "reminder_logs")).scalar_one()
    assert log.payload["created_by"] is None
    assert log.payload["actor_name"] == "Original caregiver"
    record = db.execute(select(SyncChange).where(SyncChange.table_name == "records")).scalar_one()
    assert json.loads(record.payload["payload"])["backup_actor_name"] == "Original caregiver"


@pytest.mark.parametrize("method,url,body", [
    ("GET", "/pets?owner=owner", None),
    ("GET", "/pets/pet", None),
    ("POST", "/pets?owner=owner", {"name": "New", "species": "dog"}),
    ("PATCH", "/pets/pet", {"name": "Changed", "species": "dog"}),
    ("DELETE", "/pets/pet", None),
])
def test_legacy_pet_routes_require_authentication(client, method, url, body):
    assert client.request(method, url, json=body).status_code == 401


@pytest.mark.parametrize("method", ["GET", "POST"])
def test_owner_query_cannot_impersonate_another_account(client, db, method):
    login(db, "outsider")
    body = {"name": "New", "species": "dog"} if method == "POST" else None
    assert client.request(method, "/pets?owner=owner", json=body).status_code == 403


@pytest.mark.parametrize("user_id,method,status", [
    ("outsider", "GET", 403),
    ("outsider", "PATCH", 403),
    ("outsider", "DELETE", 403),
    ("viewer", "GET", 200),
    ("viewer", "PATCH", 403),
    ("viewer", "DELETE", 403),
    ("editor", "GET", 200),
    ("editor", "PATCH", 200),
    ("editor", "DELETE", 403),
])
def test_pet_roles_control_rest_access(client, db, user_id, method, status):
    login(db, user_id)
    body = {"name": "Changed", "species": "dog"} if method == "PATCH" else None
    assert client.request(method, "/pets/pet", json=body).status_code == status


def test_rest_pet_lifecycle_creates_membership_and_sync_changes(client, db):
    login(db, "owner")
    response = client.post("/pets?owner=owner", json={"name": "New", "species": "dog"})
    assert response.status_code == 201
    pet_id = response.json()["id"]
    member = db.execute(select(Member).where(Member.pet_id == pet_id)).scalar_one_or_none()
    assert member is not None and member.role == "owner" and member.status == "active"
    assert client.patch(f"/pets/{pet_id}", json={"name": "Edited", "species": "dog"}).status_code == 200
    assert client.delete(f"/pets/{pet_id}").status_code == 204
    changes = sync_pull(since=0, limit=500, table=None, user=db.get(User, "owner"), session=db)["changes"]
    snapshots = [change for change in changes if change["table"] == "pets" and change["row_id"] == pet_id]
    assert len(snapshots) == 3
    assert snapshots[1]["payload"]["name"] == "Edited"
    assert snapshots[2]["op"] == "delete"


def test_sync_rejects_payload_id_different_from_row_id(db):
    result = push(db, "owner", "records", "one", {"id": "two", "pet_id": "pet", "updated_at": 10})
    assert result["applied"] == []
    assert result["rejected"][0]["result"] == "invalid"


def test_sync_cannot_move_an_existing_row_into_a_different_pet(db):
    original = {"id": "record", "pet_id": "pet", "updated_at": 10}
    assert push(db, "owner", "records", "record", original)["applied"]
    forged = {"id": "record", "pet_id": "other-pet", "updated_at": 20}
    result = push(db, "outsider", "records", "record", forged, timestamp=20)
    assert result["applied"] == []
    assert result["rejected"][0]["result"] == "forbidden"


def test_attachment_parent_must_belong_to_the_authorized_pet(db):
    assert push(db, "owner", "records", "record", {"id": "record", "pet_id": "pet", "updated_at": 10})["applied"]
    result = push(db, "outsider", "attachments", "attachment", {
        "id": "attachment", "record_id": "record", "pet_id": "other-pet", "updated_at": 20,
    }, timestamp=20)
    assert result["applied"] == []
    assert result["rejected"][0]["result"] == "forbidden"


def test_removed_member_can_be_invited_again_without_unique_constraint_failure(db):
    owner = db.get(User, "owner")
    remove_member("pet", "editor", user=owner, session=db)
    result = invite_member("pet", InviteIn(channel="email", target="editor@example.com", role="viewer"),
                           user=owner, session=db)
    member = db.get(Member, result["invite_id"])
    assert member.user_id == "editor" and member.deleted_at is None
    assert member.status == "pending" and member.role == "viewer"
    assert len(db.execute(select(Member).where(Member.pet_id == "pet", Member.user_id == "editor")).scalars().all()) == 1


def test_synced_pet_edits_and_deletion_update_the_authoritative_entity(db):
    payload = {"id": "pet", "name": "Renamed", "species": "dog", "created_by": "owner",
               "created_at": 1, "updated_at": 20, "deleted_at": 20}
    result = push(db, "owner", "pets", "pet", payload, timestamp=20, op="delete")
    assert result["applied"]
    assert db.get(Pet, "pet").name == "Renamed"
    assert db.get(Pet, "pet").deleted_at == 20


def test_accept_invite_replays_latest_pet_history_to_all_existing_device_cursors(db):
    owner = db.get(User, "owner")
    invited = db.get(User, "outsider")
    pet_payload = {"id": "pet", "name": "Shared", "species": "dog", "created_by": "owner",
                   "created_at": 1, "updated_at": 10}
    assert push(db, "owner", "pets", "pet", pet_payload)["applied"]
    assert push(db, "owner", "records", "record", {
        "id": "record", "pet_id": "pet", "updated_at": 10, "note": "Old",
    })["applied"]
    assert push(db, "owner", "records", "record", {
        "id": "record", "pet_id": "pet", "updated_at": 20, "note": "Latest",
    }, timestamp=20)["applied"]
    assert push(db, "owner", "records", "deleted-record", {
        "id": "deleted-record", "pet_id": "pet", "updated_at": 20, "deleted_at": 20,
    }, timestamp=20, op="delete")["applied"]
    invite = invite_member("pet", InviteIn(channel="email", target="outsider@example.com", role="viewer"),
                           user=owner, session=db)
    # Two already logged-in devices have both advanced past the pending pet's history.
    before = sync_pull(since=0, limit=500, table=None, user=invited, session=db)
    assert before["changes"] == []
    cursor = before["next_since"]
    assert cursor > 0
    assert accept_invite(invite["invite_id"], user=invited, session=db) == {"ok": True}
    for _device in range(2):
        after = sync_pull(since=cursor, limit=500, table=None, user=invited, session=db)
        pet_changes = [row for row in after["changes"] if row["table"] == "pets"]
        record_changes = [row for row in after["changes"] if row["table"] == "records"]
        assert len(pet_changes) == 1 and pet_changes[0]["payload"]["name"] == "Shared"
        assert {row["row_id"] for row in record_changes} == {"record", "deleted-record"}
        assert next(row for row in record_changes if row["row_id"] == "record")["payload"]["note"] == "Latest"
        assert next(row for row in record_changes if row["row_id"] == "deleted-record")["op"] == "delete"
    # Retrying accept must not create another history replay.
    last_seq = after["next_since"]
    assert accept_invite(invite["invite_id"], user=invited, session=db) == {"ok": True}
    assert sync_pull(since=last_seq, limit=500, table=None, user=invited, session=db)["changes"] == []


def test_sync_editor_cannot_delete_pet(db):
    result = push(db, "editor", "pets", "pet", {
        "id": "pet", "name": "Pet", "species": "dog", "created_by": "owner",
        "updated_at": 20, "deleted_at": 20,
    }, timestamp=20, op="delete")
    assert result["applied"] == []
    assert result["rejected"][0]["result"] == "forbidden"


def test_sync_cannot_publish_fake_membership(db):
    result = push(db, "owner", "members", "fake-member", {
        "id": "fake-member", "pet_id": "pet", "user_id": "outsider",
        "role": "owner", "status": "active", "joined_at": 10, "updated_at": 10,
    })
    assert result["applied"] == []
    assert result["rejected"][0]["result"] == "forbidden"


def test_bootstrap_cannot_take_over_existing_pet_without_members(db):
    db.add(Pet(id="orphan", name="Existing", species="dog", created_by="outsider",
               created_at=1, updated_at=1))
    db.commit()
    result = push(db, "owner", "pets", "orphan", {
        "id": "orphan", "name": "Stolen", "species": "dog", "created_by": "owner",
        "created_at": 1, "updated_at": 20,
    }, timestamp=20)
    assert result["applied"] == []
    assert db.get(Pet, "orphan").created_by == "outsider"


def test_removed_members_cannot_read_pet_changes_even_if_they_wrote_them():
    changes = [{"table": "records", "pet_id": "pet", "user_id": "editor"}]
    assert visible_to(changes, set(), "editor") == []


@pytest.mark.parametrize("updates", [
    {"email": "owner@example.com"},
    {"email": None},
    {"phone": "+8613800138000"},
])
def test_profile_patch_cannot_change_verified_login_identifiers(client, db, updates):
    login(db, "outsider")
    response = client.patch("/api/v1/me", json=updates)
    assert response.status_code == 400
    assert db.get(User, "outsider").email == "outsider@example.com"
    assert db.get(User, "outsider").phone is None


def test_profile_patch_keeps_normalized_identifiers_and_updates_contact(client, db):
    login(db, "owner")
    response = client.patch("/api/v1/me", json={
        "email": " OWNER@example.com ", "nickname": "New", "wechat": "pet-owner",
    })
    assert response.status_code == 200
    assert db.get(User, "owner").email == "owner@example.com"
    assert db.get(User, "owner").nickname == "New"


@pytest.mark.parametrize("timestamp", [100, 99])
def test_stale_response_contains_authoritative_snapshot(db, timestamp):
    owner = db.get(User, "owner")
    winner = PushChangeIn(table="records", row_id="tie", updated_at=100,
                          payload={"pet_id": "pet", "note": "winner"})
    sync_push(PushIn(changes=[winner]), user=owner, session=db)
    loser = winner.model_copy(update={"updated_at": timestamp,
                                     "payload": {"pet_id": "pet", "note": "loser"}})
    result = sync_push(PushIn(changes=[loser]), user=owner, session=db)
    canonical = result["rejected"][0]["canonical"]
    assert canonical["payload"]["note"] == "winner"
    assert canonical["changed_at"] == 100
    assert canonical["table"] == "records" and canonical["row_id"] == "tie"
    assert canonical["seq"] > 0
    denied = sync_push(PushIn(changes=[loser]), user=db.get(User, "outsider"), session=db)
    assert "canonical" not in denied["rejected"][0]


def test_empty_pull_does_not_skip_a_commit_between_page_and_visibility(db, monkeypatch):
    from app import sync
    original = sync.active_member_pet_ids
    def commit_after_page(session, user_id):
        session.add(SyncChange(table_name="records", row_id="late", op="upsert",
                               pet_id="pet", user_id="owner", changed_at=100,
                               payload={"id": "late", "pet_id": "pet"}))
        session.commit()
        return original(session, user_id)
    monkeypatch.setattr(sync, "active_member_pet_ids", commit_after_page)
    owner = db.get(User, "owner")
    page = sync_pull(since=0, limit=200, table=None, user=owner, session=db)
    assert page["changes"] == [] and page["next_since"] == 0
    monkeypatch.setattr(sync, "active_member_pet_ids", original)
    next_page = sync_pull(since=page["next_since"], limit=200, table=None, user=owner, session=db)
    assert next_page["changes"][0]["row_id"] == "late"


def test_removed_member_receives_only_own_revocation(db):
    owner, editor = db.get(User, "owner"), db.get(User, "editor")
    sync_push(PushIn(changes=[PushChangeIn(table="records", row_id="secret", updated_at=100,
              payload={"pet_id": "pet", "note": "private"})]), user=owner, session=db)
    remove_member("pet", "editor", user=owner, session=db)
    remove_member("pet", "viewer", user=owner, session=db)
    page = sync_pull(since=0, limit=200, table=None, user=editor, session=db)
    assert len(page["changes"]) == 1
    tombstone = page["changes"][0]
    assert tombstone["table"] == "members" and tombstone["op"] == "delete"
    assert tombstone["payload"]["user_id"] == "editor"
    assert tombstone["payload"]["deleted_at"] is not None
