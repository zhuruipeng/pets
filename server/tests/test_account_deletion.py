"""Account deletion exercises real authentication, FK constraints and files."""
import hashlib
import json

import pytest
from sqlalchemy import select

from app.account_deletion import purge_pending_media
from app.auth import current_user
from app.config import Settings, get_settings
from app.main import app
from app.models import (AuthToken, DeletedSession, Member, PendingMediaDeletion,
                        Pet, PhotoBlob, SyncChange, User, VerifyCode)
from app.sync_logic import hash_token, now_ms
from test_review_regressions import client, db, push


@pytest.fixture
def deletion(client, db, tmp_path):
    settings = Settings(media_directory=tmp_path / 'private')
    app.dependency_overrides[get_settings] = lambda: settings
    def authenticate(user_id):
        app.dependency_overrides.pop(current_user, None)
        token = 'deletion-token-' + user_id
        if db.get(AuthToken, hash_token(token)) is None:
            db.add(AuthToken(token=hash_token(token), user_id=user_id,
                created_at=now_ms(), expires_at=now_ms() + 60_000))
            db.commit()
        return {'Authorization': 'Bearer ' + token}
    return client, db, settings, authenticate


def erase(client, headers, confirmation='DELETE'):
    return client.request('DELETE', '/api/v1/me', headers=headers,
                          json={'confirmation': confirmation})


def test_requires_auth_and_explicit_confirmation(deletion):
    client, db, _, authenticate = deletion
    assert erase(client, {}).status_code == 401
    assert erase(client, authenticate('outsider'), '').status_code == 422
    assert db.get(User, 'outsider') is not None


def test_shared_owner_block_is_atomic(deletion):
    client, db, _, authenticate = deletion
    headers = authenticate('owner')
    assert erase(client, headers).status_code == 409
    assert client.get('/api/v1/me', headers=headers).status_code == 200
    assert db.get(Pet, 'pet') is not None
    assert db.get(Member, 'member-editor') is not None


def test_private_data_files_tokens_codes_and_snapshots_are_erased(deletion):
    client, db, settings, authenticate = deletion
    push(db, 'outsider', 'records', 'private-record', {'pet_id': 'other-pet',
        'type': 'note', 'recorded_at': 1, 'created_at': 1}, timestamp=10)
    digest = hashlib.sha256(b'photo').hexdigest()
    path = settings.media_directory / 'photo' / digest
    path.parent.mkdir(parents=True)
    path.write_bytes(b'photo')
    db.add(PhotoBlob(attachment_id='photo', sha256=digest, pet_id='other-pet',
        record_id='private-record', content_type='image/png', size_bytes=5, created_at=1))
    db.add(VerifyCode(channel='email', target='outsider@example.com', purpose='login',
        code='123456', created_at=1, expires_at=now_ms()+60_000))
    db.add(AuthToken(token=hash_token('another-device'), user_id='outsider',
        created_at=1, expires_at=now_ms()+60_000))
    db.commit()
    headers = authenticate('outsider')
    assert erase(client, headers).status_code == 200
    assert db.get(User, 'outsider') is None
    assert db.get(Pet, 'other-pet') is None
    assert not path.exists()
    assert not db.execute(select(PhotoBlob)).scalars().all()
    assert not db.execute(select(AuthToken).where(AuthToken.user_id == 'outsider')).scalars().all()
    assert not db.execute(select(VerifyCode)).scalars().all()
    assert not db.execute(select(SyncChange).where(SyncChange.table_name == 'records',
        SyncChange.row_id == 'private-record')).scalars().all()
    assert client.get('/api/v1/me', headers=headers).status_code == 401
    assert client.get('/api/v1/me', headers={'Authorization':'Bearer another-device'}).status_code == 401
    # Lost-response retry succeeds with the original token, without recreating data.
    assert erase(client, headers).json() == {'ok': True}
    assert erase(client, {'Authorization': 'bearer  deletion-token-outsider '}).json() == {'ok': True}
    assert erase(client, {'Authorization':'Bearer another-device'}).status_code == 401
    receipt = db.get(DeletedSession, hash_token('deletion-token-outsider'))
    receipt.expires_at = 1
    db.commit()
    assert erase(client, headers).status_code == 401
    assert db.get(Pet, 'pet') is not None


def test_shared_member_preserves_care_facts_and_anonymizes_history(deletion):
    client, db, _, authenticate = deletion
    push(db, 'editor', 'records', 'shared-record', {'pet_id': 'pet',
        'type': 'note', 'recorded_at': 1, 'created_at': 1,
        'created_by': 'editor', 'payload': '{"actor_name":"editor"}'}, timestamp=10)
    headers = authenticate('editor')
    assert erase(client, headers).status_code == 200
    assert db.get(User, 'editor') is None
    assert db.get(Member, 'member-editor') is None
    assert db.get(Pet, 'pet').created_by == 'owner'
    changes = db.execute(select(SyncChange).where(SyncChange.row_id == 'shared-record')
                         .order_by(SyncChange.seq)).scalars().all()
    assert changes
    assert all(c.payload['created_by'] == 'deleted-user' for c in changes)
    assert all(c.user_id != 'editor' for c in changes)
    assert all(json.loads(c.payload['payload'])['actor_name'] == 'Deleted account' for c in changes)
    # A remaining carer's stale offline edit cannot restore the erased identity.
    result = push(db, 'owner', 'records', 'shared-record', {'pet_id': 'pet',
        'type': 'note', 'recorded_at': 1, 'created_at': 1,
        'created_by': 'editor', 'payload': '{"actor_name":"editor"}'},
        timestamp=now_ms() + 1000)
    assert result['applied']
    latest = db.execute(select(SyncChange).where(SyncChange.row_id == 'shared-record')
                        .order_by(SyncChange.seq.desc())).scalars().first()
    assert latest.payload['created_by'] == 'deleted-user'
    assert 'editor' not in json.dumps(latest.payload)
    owner = authenticate('owner')
    pulled = client.get('/api/v1/sync/pull', params={'since': 0}, headers=owner)
    assert pulled.status_code == 200
    assert any(c['row_id'] == 'member-editor' and c['op'] == 'delete'
               for c in pulled.json()['changes'])
    assert client.get('/api/v1/pets/pet/members', headers=owner).status_code == 200


def test_pending_invitation_does_not_block_private_owner(deletion):
    client, db, _, authenticate = deletion
    db.add(Member(id='pending', pet_id='other-pet', user_id='viewer', role='viewer',
                  status='pending', joined_at=1))
    db.commit()
    assert erase(client, authenticate('outsider')).status_code == 200
    assert db.get(Member, 'pending') is None
    assert db.get(User, 'viewer') is not None


def test_file_cleanup_queue_survives_unlink_failure(deletion, monkeypatch):
    from pathlib import Path
    client, db, settings, authenticate = deletion
    digest = 'a' * 64
    path = settings.media_directory / 'photo' / digest
    path.parent.mkdir(parents=True)
    path.write_bytes(b'photo')
    db.add(PhotoBlob(attachment_id='photo', sha256=digest, pet_id='other-pet',
        record_id='r', content_type='image/png', size_bytes=5, created_at=1))
    db.commit()
    original = Path.unlink
    def fail(target, *args, **kwargs):
        if target == path: raise PermissionError('locked')
        return original(target, *args, **kwargs)
    monkeypatch.setattr(Path, 'unlink', fail)
    assert erase(client, authenticate('outsider')).status_code == 200
    assert db.get(PendingMediaDeletion, ('photo', digest)) is not None
    assert db.get(PhotoBlob, ('photo', digest)) is None
    monkeypatch.setattr(Path, 'unlink', original)
    purge_pending_media(db, settings)
    assert not path.exists()
    assert db.get(PendingMediaDeletion, ('photo', digest)) is None


def test_database_failure_rolls_back_all_erasure(deletion, monkeypatch):
    from app import account_deletion
    client, db, _, authenticate = deletion
    headers = authenticate('outsider')
    original = account_deletion.record_change
    def fail(*args, **kwargs):
        original(*args, **kwargs)
        raise RuntimeError('interrupted transaction')
    monkeypatch.setattr(account_deletion, 'record_change', fail)
    with pytest.raises(RuntimeError):
        erase(client, headers)
    db.rollback()
    assert db.get(User, 'outsider') is not None
    assert db.get(Pet, 'other-pet') is not None
    assert client.get('/api/v1/me', headers=headers).status_code == 200
